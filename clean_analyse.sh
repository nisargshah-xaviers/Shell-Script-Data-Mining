#!/bin/bash

# CSV/XLSX Analysis Pipeline with SQLite and Streamlit Dashboard
# Enhanced with Data Cleaning and Advanced Analytics

set -e  # Exit on error

# Configuration
INPUT_FILE="${1:-data.csv}"
CLEANED_FILE="cleaned_data.csv"
DB_FILE="analysis.db"
DASHBOARD_FILE="dashboard.py"

echo "=== Enhanced Data Analysis Pipeline ==="
echo "Input file: $INPUT_FILE"
echo ""

# Step 1: Data Cleaning using Shell Utilities
echo "Step 1: Cleaning data with shell utilities..."

# Extract header
head -n 1 "$INPUT_FILE" > "$CLEANED_FILE"

# Clean the data
tail -n +2 "$INPUT_FILE" | \
    sed 's/\r$//' | \
    sed 's/[[:space:]]*,[[:space:]]*/,/g' | \
    sed 's/"//g' | \
    awk -F',' '
    {
        # Clean ID (remove non-numeric chars if present)
        id = $1
        gsub(/[^0-9]/, "", id)
        
        # Clean amounts (remove currency symbols, handle nulls)
        total = $2
        gsub(/[$,]/, "", total)
        if (total == "" || total == "NULL" || total == "null") total = 0
        
        due = $3
        gsub(/[$,]/, "", due)
        if (due == "" || due == "NULL" || due == "null") due = 0
        
        # Validate: due cannot exceed total
        if (due > total) due = total
        if (due < 0) due = 0
        if (total < 0) total = 0
        
        # Clean dates (standardize format, handle nulls)
        issue_date = $4
        gsub(/ UTC$/, "", issue_date)
        gsub(/\.000000/, "", issue_date)
        
        due_date = $5
        gsub(/ UTC$/, "", due_date)
        gsub(/\.000000/, "", due_date)
        
        paid_date = $6
        gsub(/ UTC$/, "", paid_date)
        gsub(/\.000000/, "", paid_date)
        if (paid_date == "" || paid_date == "NULL" || paid_date == "null" || paid_date == "NaT") {
            paid_date = ""
        }
        
        # Clean payer_id (trim whitespace)
        payer = $7
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", payer)
        
        # Output cleaned row
        if (id != "" && total != "" && payer != "") {
            printf "%s,%s,%s,%s,%s,%s,%s\n", id, total, due, issue_date, due_date, paid_date, payer
        }
    }' >> "$CLEANED_FILE"

TOTAL_RECORDS=$(tail -n +2 "$CLEANED_FILE" | wc -l)
echo "✓ Cleaned $TOTAL_RECORDS records"
echo "✓ Saved to: $CLEANED_FILE"
echo ""

# Step 2: Analyze the data using shell utilities
echo "Step 2: Performing advanced analysis..."

# Get header
HEADER=$(head -n 1 "$CLEANED_FILE")
echo "Columns: $HEADER"
echo ""

# Analysis 1: Records by month
echo "Creating analysis: Records by month..."
tail -n +2 "$CLEANED_FILE" | \
    awk -F',' '{
        date=$4
        gsub(/ .*/, "", date)
        gsub(/-[0-9][0-9]$/, "", date)
        if (date != "") month_counts[date]++
    }
    END {
        for (month in month_counts) {
            printf "%s,%d\n", month, month_counts[month]
        }
    }' | sort > month_analysis.tmp

# Analysis 2: Payment status analysis
echo "Creating analysis: Payment status..."
tail -n +2 "$CLEANED_FILE" | \
    awk -F',' '{
        total_amount=$2
        amount_due=$3
        
        if (amount_due > total_amount) amount_due = total_amount
        
        paid_portion = total_amount - amount_due
        
        grand_total += total_amount
        grand_due += amount_due
        grand_paid += paid_portion
        
        if (amount_due == 0) {
            full_paid_count++
            full_paid_total += total_amount
        } else if (amount_due == total_amount) {
            unpaid_count++
            unpaid_total += amount_due
        } else {
            partial_count++
            partial_paid_total += paid_portion
            partial_due_total += amount_due
        }
    }
    END {
        printf "Fully Paid,%d,%.2f\n", full_paid_count, full_paid_total
        printf "Partially Paid,%d,%.2f\n", partial_count, partial_paid_total
        printf "Outstanding,%d,%.2f\n", unpaid_count + partial_count, unpaid_total + partial_due_total
    }' > status_analysis.tmp

# Analysis 3: Top payers
echo "Creating analysis: Top payers..."
tail -n +2 "$CLEANED_FILE" | \
    awk -F',' '{
        payer=$7
        total=$2
        payer_total[payer]+=total
        payer_count[payer]++
    }
    END {
        for (p in payer_total) {
            printf "%s,%.2f,%d\n", p, payer_total[p], payer_count[p]
        }
    }' | sort -t',' -k2 -rn | head -20 > payer_analysis.tmp

# Analysis 4: Payment delay analysis
echo "Creating analysis: Payment timing..."
tail -n +2 "$CLEANED_FILE" | \
    awk -F',' '{
        total=$2
        amount_due=$3
        due_date=$5
        paid_date=$6
        
        gsub(/ .*/, "", due_date)
        gsub(/ .*/, "", paid_date)
        
        if (amount_due == "" || amount_due == "NULL") amount_due = 0
        if (amount_due > total) amount_due = total
        
        paid_amount = total - amount_due
        
        if (amount_due > 0) {
            unpaid_count++
            unpaid_total+=amount_due
        }

        if (paid_amount > 0) {
            if (paid_date != "" && paid_date != "NULL" && paid_date != "null" && paid_date != "NaT") {
                if (paid_date > due_date) {
                    late_count++
                    late_total+=paid_amount
                } else {
                    ontime_count++
                    ontime_total+=paid_amount
                }
            } else {
                unknown_count++
                unknown_total+=paid_amount
            }
        }
    }
    END {
        printf "On Time,%d,%.2f\n", ontime_count, ontime_total
        printf "Late,%d,%.2f\n", late_count, late_total
        printf "Unknown Date,%d,%.2f\n", unknown_count, unknown_total
        printf "Unpaid,%d,%.2f\n", unpaid_count, unpaid_total
    }' > payment_timing.tmp

# NEW Analysis 5: Average payment delay in days
echo "Creating analysis: Payment delay metrics..."
tail -n +2 "$CLEANED_FILE" | \
    awk -F',' '
    function date_to_days(date) {
        split(date, parts, "-")
        year = parts[1]
        month = parts[2]
        day = parts[3]
        gsub(/ .*/, "", day)
        return year*365 + month*30 + day
    }
    {
        total=$2
        amount_due=$3
        due_date=$5
        paid_date=$6
        
        gsub(/ .*/, "", due_date)
        gsub(/ .*/, "", paid_date)
        
        if (amount_due > total) amount_due = total
        paid_amount = total - amount_due
        
        if (paid_amount > 0 && paid_date != "" && paid_date != "NULL" && due_date != "") {
            delay = date_to_days(paid_date) - date_to_days(due_date)
            
            if (delay <= 0) {
                early_or_ontime++
            } else if (delay <= 7) {
                delay_1_7++
            } else if (delay <= 30) {
                delay_8_30++
            } else if (delay <= 90) {
                delay_31_90++
            } else {
                delay_90_plus++
            }
        }
    }
    END {
        printf "On Time/Early,%d\n", early_or_ontime
        printf "1-7 Days Late,%d\n", delay_1_7
        printf "8-30 Days Late,%d\n", delay_8_30
        printf "31-90 Days Late,%d\n", delay_31_90
        printf "90+ Days Late,%d\n", delay_90_plus
    }' > delay_buckets.tmp

# NEW Analysis 6: Payer reliability score
echo "Creating analysis: Payer reliability..."
tail -n +2 "$CLEANED_FILE" | \
    awk -F',' '{
        payer=$7
        total=$2
        amount_due=$3
        due_date=$5
        paid_date=$6
        
        gsub(/ .*/, "", due_date)
        gsub(/ .*/, "", paid_date)
        
        if (amount_due > total) amount_due = total
        paid_amount = total - amount_due
        
        payer_total[payer] += total
        payer_invoices[payer]++
        
        if (amount_due == 0) {
            payer_fully_paid[payer]++
        }
        
        if (paid_amount > 0 && paid_date != "" && due_date != "" && paid_date <= due_date) {
            payer_ontime[payer]++
        }
    }
    END {
        for (p in payer_total) {
            total_inv = payer_invoices[p]
            fully_paid = (payer_fully_paid[p] ? payer_fully_paid[p] : 0)
            ontime = (payer_ontime[p] ? payer_ontime[p] : 0)
            
            payment_rate = (fully_paid / total_inv) * 100
            ontime_rate = (ontime / total_inv) * 100
            reliability = (payment_rate * 0.6 + ontime_rate * 0.4)
            
            printf "%s,%.2f,%.1f,%.1f,%.1f,%d\n", p, payer_total[p], payment_rate, ontime_rate, reliability, total_inv
        }
    }' | sort -t',' -k5 -rn | head -20 > payer_reliability.tmp

# NEW Analysis 7: Quarterly trends
echo "Creating analysis: Quarterly revenue trends..."
tail -n +2 "$CLEANED_FILE" | \
    awk -F',' '{
        total=$2
        amount_due=$3
        date=$4
        
        if (amount_due > total) amount_due = total
        paid_amount = total - amount_due
        
        gsub(/ .*/, "", date)
        split(date, parts, "-")
        year = parts[1]
        month = parts[2]
        
        quarter = int((month-1)/3) + 1
        period = year "-Q" quarter
        
        q_invoiced[period] += total
        q_collected[period] += paid_amount
        q_outstanding[period] += amount_due
        q_count[period]++
    }
    END {
        for (q in q_invoiced) {
            printf "%s,%.2f,%.2f,%.2f,%d\n", q, q_invoiced[q], q_collected[q], q_outstanding[q], q_count[q]
        }
    }' | sort > quarterly_trends.tmp

echo "✓ Analysis complete"
echo ""

# Step 3: Store results in SQLite database
echo "Step 3: Storing results in SQLite database..."

rm -f "$DB_FILE"

sqlite3 "$DB_FILE" << 'SQL'
CREATE TABLE invoices (
    row_id INTEGER PRIMARY KEY AUTOINCREMENT,
    id TEXT,
    total_amount REAL,
    amount_due REAL,
    issue_date TEXT,
    due_date TEXT,
    paid_on_date TEXT,
    payer_id TEXT
);

CREATE TABLE monthly_summary (
    month TEXT PRIMARY KEY,
    invoice_count INTEGER
);

CREATE TABLE payment_status (
    status TEXT PRIMARY KEY,
    count INTEGER,
    total_amount REAL
);

CREATE TABLE top_payers (
    payer_id TEXT PRIMARY KEY,
    total_amount REAL,
    invoice_count INTEGER
);

CREATE TABLE payment_timing (
    timing_status TEXT PRIMARY KEY,
    count INTEGER,
    total_amount REAL
);

CREATE TABLE delay_buckets (
    delay_range TEXT PRIMARY KEY,
    count INTEGER
);

CREATE TABLE payer_reliability (
    payer_id TEXT PRIMARY KEY,
    total_amount REAL,
    payment_rate REAL,
    ontime_rate REAL,
    reliability_score REAL,
    invoice_count INTEGER
);

CREATE TABLE quarterly_trends (
    quarter TEXT PRIMARY KEY,
    total_invoiced REAL,
    total_collected REAL,
    total_outstanding REAL,
    invoice_count INTEGER
);
SQL

# Import data using Python
echo "Importing data into database..."

python3 << 'PYEOF'
import sqlite3
import csv

conn = sqlite3.connect('analysis.db')
cursor = conn.cursor()

# Import main invoice data
with open('cleaned_data.csv', 'r') as f:
    reader = csv.DictReader(f)
    batch = []
    for row in reader:
        # Handle different possible column names
        row_id = row.get('id', row.get('ID', ''))
        total_amt = row.get('total_amount', row.get('Total Amount', '0'))
        amt_due = row.get('amount_due', row.get('Amount Due', '0'))
        issue_dt = row.get('issue_date', row.get('Issue Date', ''))
        due_dt = row.get('due_date', row.get('Due Date', ''))
        paid_dt = row.get('paid_on_date', row.get('Paid On Date', ''))
        payer = row.get('payer_id', row.get('Payer ID', ''))
        
        # Convert to proper types
        total = float(total_amt) if total_amt and total_amt != '' else 0
        due = float(amt_due) if amt_due and amt_due != '' else 0
        
        if due > total:
            due = total
            
        batch.append((
            row_id, total, due,
            issue_dt, due_dt,
            paid_dt if paid_dt not in ['', 'NaT', 'NULL', 'null'] else None,
            payer
        ))
        
        if len(batch) >= 1000:
            cursor.executemany('INSERT INTO invoices (id, total_amount, amount_due, issue_date, due_date, paid_on_date, payer_id) VALUES (?,?,?,?,?,?,?)', batch)
            batch = []

    if batch:
        cursor.executemany('INSERT INTO invoices (id, total_amount, amount_due, issue_date, due_date, paid_on_date, payer_id) VALUES (?,?,?,?,?,?,?)', batch)

# Import summaries
def import_csv(filename, table, columns):
    try:
        with open(filename, 'r') as f:
            for line in f:
                parts = line.strip().split(',')
                if len(parts) == columns:
                    cursor.execute(f"INSERT INTO {table} VALUES ({','.join(['?']*columns)})", parts)
    except FileNotFoundError:
        pass

import_csv('month_analysis.tmp', 'monthly_summary', 2)
import_csv('status_analysis.tmp', 'payment_status', 3)
import_csv('payer_analysis.tmp', 'top_payers', 3)
import_csv('payment_timing.tmp', 'payment_timing', 3)
import_csv('delay_buckets.tmp', 'delay_buckets', 2)
import_csv('payer_reliability.tmp', 'payer_reliability', 6)
import_csv('quarterly_trends.tmp', 'quarterly_trends', 5)

conn.commit()
conn.close()
print("✓ Data imported successfully")
PYEOF

# Clean up temp files
rm -f *.tmp

echo "✓ Database created: $DB_FILE"
echo ""

# Step 4: Create Enhanced Streamlit dashboard
echo "Step 4: Creating enhanced Streamlit dashboard..."

cat > "$DASHBOARD_FILE" << 'PYTHON'
import streamlit as st
import sqlite3
import pandas as pd
import plotly.express as px
import plotly.graph_objects as go

st.set_page_config(page_title="Invoice Analytics Dashboard", layout="wide", page_icon="📊")

conn = sqlite3.connect('analysis.db', check_same_thread=False)

def load_data(query):
    return pd.read_sql_query(query, conn)

# Custom CSS
st.markdown("""
<style>
    .metric-card {
        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        padding: 20px;
        border-radius: 10px;
        color: white;
    }
</style>
""", unsafe_allow_html=True)

st.title("📊 Invoice Analytics Dashboard")
st.markdown("### Comprehensive Invoice Payment Analysis")
st.markdown("---")

# 1. GLOBAL METRICS
invoices_df = load_data("SELECT total_amount, amount_due FROM invoices")
invoices_df['cash_collected'] = (invoices_df['total_amount'] - invoices_df['amount_due']).clip(lower=0)

total_invoiced = invoices_df['total_amount'].sum()
total_collected = invoices_df['cash_collected'].sum()
total_outstanding = invoices_df['amount_due'].sum()
count = len(invoices_df)
collection_rate = (total_collected/total_invoiced*100) if total_invoiced > 0 else 0

col1, col2, col3, col4, col5 = st.columns(5)
with col1:
    st.markdown("**Total Invoiced**")
    st.markdown(f"### ${total_invoiced:,.0f}")
with col2:
    st.markdown("**Cash Collected**")
    st.markdown(f"### ${total_collected:,.0f}")
with col3:
    st.markdown("**Outstanding**")
    st.markdown(f"### ${total_outstanding:,.0f}")
with col4:
    st.markdown("**Cash Collection Rate**")
    st.markdown(f"### {collection_rate:.1f}%")
with col5:
    st.markdown("**Total Invoices**")
    st.markdown(f"### {count:,}")

st.markdown("---")

# Create tabs for different analyses
tab1, tab2, tab3 = st.tabs([
    "⏰ Payment Timing", 
    "💰 Payment Status",
    "🔍 Data Filter"
])

with tab2:
    col1, col2 = st.columns(2)
    
    # Payment Status
    with col1:
        st.subheader("💰 Payment Status Distribution")
        status_data = load_data("SELECT * FROM payment_status")
        
        if not status_data.empty:
            fig = px.pie(status_data, values='total_amount', names='status', hole=0.4,
                         color_discrete_map={'Fully Paid':'#2ecc71', 'Partially Paid':'#f1c40f', 'Outstanding':'#e74c3c'})
            st.plotly_chart(fig, use_container_width=True, key="overview_status_pie")
            
            display_status = status_data.copy()
            display_status['total_amount'] = display_status['total_amount'].apply(lambda x: f"${x:,.0f}")
            display_status.columns = ["Status", "Count", "Amount"]
            st.dataframe(display_status, use_container_width=True, hide_index=True)
    
    # Quarterly Trends
    with col2:
        st.subheader("🏆 Top 10 Payers by Value")
        top_payers = load_data("SELECT * FROM top_payers LIMIT 10")
        
        if not top_payers.empty:
            fig = px.bar(top_payers, x='total_amount', y='payer_id', orientation='h',
                        color='total_amount', color_continuous_scale='Viridis')
            fig.update_layout(yaxis={'categoryorder':'total ascending'})
            st.plotly_chart(fig, use_container_width=True, key="top_payers_bar")

with tab1:
    col1, col2 = st.columns(2)
    
    with col1:
        st.subheader("⏰ Payment Timing Distribution")
        timing_data = load_data("SELECT * FROM payment_timing")
        
        if not timing_data.empty:
            fig = px.bar(timing_data, x='timing_status', y='total_amount', color='timing_status',
                         color_discrete_map={'On Time':'#27ae60', 'Late':'#e67e22', 
                                           'Unknown Date':'#95a5a6', 'Unpaid':'#c0392b'})
            st.plotly_chart(fig, use_container_width=True, key="payment_timing_bar")
            
            display_timing = timing_data.copy()
            display_timing['total_amount'] = display_timing['total_amount'].apply(lambda x: f"${x:,.0f}")
            display_timing.columns = ["Timing", "Count", "Amount"]
            st.dataframe(display_timing, use_container_width=True, hide_index=True)
    with col2:
        st.subheader("📊 Quarterly Revenue Trends")
        quarterly_data = load_data("SELECT * FROM quarterly_trends ORDER BY quarter")
        
        if not quarterly_data.empty:
            fig = go.Figure()
            fig.add_trace(go.Bar(x=quarterly_data['quarter'], y=quarterly_data['total_invoiced'], 
                                name='Invoiced', marker_color='lightblue'))
            fig.add_trace(go.Bar(x=quarterly_data['quarter'], y=quarterly_data['total_collected'], 
                                name='Collected', marker_color='green'))
            fig.update_layout(barmode='group', xaxis_title='Quarter', yaxis_title='Amount ($)')
            st.plotly_chart(fig, use_container_width=True, key="quarterly_trends_chart")

            # --- Table ---
            display_q = quarterly_data.copy()
            display_q['total_invoiced'] = display_q['total_invoiced'].apply(lambda x: f"${x:,.0f}")
            display_q['total_collected'] = display_q['total_collected'].apply(lambda x: f"${x:,.0f}")
            display_q['total_outstanding'] = display_q['total_outstanding'].apply(lambda x: f"${x:,.0f}")

            st.dataframe(
                display_q,
                use_container_width=True,
                hide_index=True
            )

    # Monthly Volume
    st.subheader("📅 Monthly Invoice Volume")
    monthly_data = load_data("SELECT * FROM monthly_summary ORDER BY month")
    if not monthly_data.empty:
        fig = px.line(monthly_data, x='month', y='invoice_count', markers=True)
        fig.update_layout(xaxis_title='Month', yaxis_title='Invoice Count')
        st.plotly_chart(fig, use_container_width=True, key="monthly_volume_chart")

    col1, col2 = st.columns([2, 1])

    with col1:
        st.subheader("⏱️ Payment Delay Analysis")
        delay_data = load_data("SELECT * FROM delay_buckets")
        
        if not delay_data.empty:
            fig = px.funnel(delay_data, x='count', y='delay_range', 
                           color='delay_range',
                           color_discrete_sequence=['#27ae60', '#f39c12', '#e67e22', '#c0392b', '#8b0000'])
            st.plotly_chart(fig, use_container_width=True, key="delay_funnel")
    
    with col2:
        if not delay_data.empty:
            st.markdown("### Delay Breakdown")
            for _, row in delay_data.iterrows():
                st.metric(row['delay_range'], f"{row['count']:,} invoices")

with tab3:
    st.subheader("📋 Invoice Explorer")
    
    col1, col2, col3 = st.columns(3)
    filter_type = col1.selectbox("Filter:", ["All Invoices", "Fully Paid Only", 
                                             "Partially Paid", "Unpaid"], key="explorer_filter")
    search_id = col2.text_input("Payer Search:", key="explorer_search")
    min_amount = col3.number_input("Min Amount:", min_value=0.0, value=0.0, step=1000.0)
    
    base_query = f"SELECT * FROM invoices WHERE total_amount >= {min_amount}"
    if filter_type == "Fully Paid Only":
        base_query += " AND amount_due = 0"
    elif filter_type == "Partially Paid":
        base_query += " AND amount_due > 0 AND amount_due < total_amount"
    elif filter_type == "Unpaid":
        base_query += " AND amount_due = total_amount"
    
    if search_id:
        base_query += f" AND payer_id LIKE '%{search_id}%'"
    
    df_filtered = load_data(base_query)
    
    if not df_filtered.empty:
        df_filtered['cash_paid'] = (df_filtered['total_amount'] - df_filtered['amount_due']).clip(lower=0)
        df_filtered['payment_status'] = df_filtered.apply(
            lambda x: 'Fully Paid' if x['amount_due'] == 0 
            else ('Unpaid' if x['amount_due'] == x['total_amount'] else 'Partially Paid'), 
            axis=1
        )
        
        m1, m2, m3, m4 = st.columns(4)
        m1.metric("Filtered Count", len(df_filtered))
        m2.metric("Total Value", f"${df_filtered['total_amount'].sum():,.0f}")
        m3.metric("Cash Collected", f"${df_filtered['cash_paid'].sum():,.0f}")
        m4.metric("Outstanding", f"${df_filtered['amount_due'].sum():,.0f}")
        
        display_df = df_filtered.copy()
        display_df['total_amount'] = display_df['total_amount'].apply(lambda x: f"${x:,.2f}")
        display_df['amount_due'] = display_df['amount_due'].apply(lambda x: f"${x:,.2f}")
        display_df['cash_paid'] = display_df['cash_paid'].apply(lambda x: f"${x:,.2f}")
    
        st.dataframe(
            display_df,
            use_container_width=True
        )
        
        # Download button
        csv = df_filtered.to_csv(index=False)
        st.download_button(
            label="📥 Download Filtered Data as CSV",
            data=csv,
            file_name="filtered_invoices.csv",
            mime="text/csv"
        )
    else:
        st.info("No matching records found.")

st.markdown("---")
st.markdown("*Dashboard by Nisarg Shah*")

PYTHON

echo "✓ Enhanced dashboard created: $DASHBOARD_FILE"
echo ""

echo "=== Pipeline Complete ==="
echo "✓ Data cleaned and stored in: $CLEANED_FILE"
echo "✓ Database created: $DB_FILE"
echo "✓ Dashboard ready: $DASHBOARD_FILE"

# Auto-launch logic
read -p "Launch dashboard now? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    streamlit run "$DASHBOARD_FILE"
fi