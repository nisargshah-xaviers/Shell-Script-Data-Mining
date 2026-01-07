#!/bin/bash

# CSV/XLSX Analysis Pipeline with SQLite and Streamlit Dashboard
# FIXED: Restored Data Tables for Status & Timing

set -e  # Exit on error

# Configuration
INPUT_FILE="${1:-data.csv}"
DB_FILE="analysis.db"
DASHBOARD_FILE="dashboard.py"

echo "=== Data Analysis Pipeline ==="
echo "Input file: $INPUT_FILE"
echo ""

# Step 2: Analyze the data using shell utilities
echo "Step 2: Analyzing data..."

# Get header
HEADER=$(head -n 1 "$INPUT_FILE")
echo "Columns: $HEADER"

# Count total records
TOTAL_RECORDS=$(tail -n +2 "$INPUT_FILE" | wc -l)
echo "Total records: $TOTAL_RECORDS"
echo ""

# Analysis 1: Summary statistics by date
echo "Creating analysis: Records by month..."
tail -n +2 "$INPUT_FILE" | \
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

# Analysis 2: Payment status analysis (Updated for Partial Payments)
echo "Creating analysis: Payment status..."
tail -n +2 "$INPUT_FILE" | \
    awk -F',' '{
        total_amount=$2
        amount_due=$3
        
        # Sanity check for bad data (Due > Total)
        if (amount_due > total_amount) amount_due = total_amount
        
        paid_portion = total_amount - amount_due
        
        # Accumulate Totals
        grand_total += total_amount
        grand_due += amount_due
        grand_paid += paid_portion
        
        # Bucketing
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
        # We output status based on CASH collected vs outstanding
        printf "Fully Paid,%d,%.2f\n", full_paid_count, full_paid_total
        printf "Partially Paid,%d,%.2f\n", partial_count, partial_paid_total
        printf "Outstanding,%d,%.2f\n", unpaid_count + partial_count, unpaid_total + partial_due_total
    }' > status_analysis.tmp

# Analysis 3: Top payers
echo "Creating analysis: Top payers..."
tail -n +2 "$INPUT_FILE" | \
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

# Analysis 4: Payment delay analysis (FIXED LOGIC)
echo "Creating analysis: Payment delays..."
tail -n +2 "$INPUT_FILE" | \
    awk -F',' '{
        total=$2
        amount_due=$3
        due_date=$5
        paid_date=$6
        
        # Clean up date strings
        gsub(/ .*/, "", due_date)
        gsub(/ .*/, "", paid_date)
        
        # Fix bad data & calculate actual paid cash
        if (amount_due == "" || amount_due == "NULL") amount_due = 0
        if (amount_due > total) amount_due = total # Cap bad data
        
        paid_amount = total - amount_due
        
        # 1. Handle Unpaid Portion
        if (amount_due > 0) {
            unpaid_count++
            unpaid_total+=amount_due
        }

        # 2. Handle Paid Portion
        if (paid_amount > 0) {
            # Check if we have a valid date to compare
            if (paid_date != "" && paid_date != "NULL" && paid_date != "null" && paid_date != "NaT") {
                if (paid_date > due_date) {
                    late_count++
                    late_total+=paid_amount
                } else {
                    ontime_count++
                    ontime_total+=paid_amount
                }
            } else {
                # Paid, but date is missing/NaT -> Goes to "Unknown" bucket
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

echo "✓ Analysis complete"
echo ""

# Step 3: Store results in SQLite database
echo "Step 3: Storing results in SQLite database..."

rm -f "$DB_FILE"

sqlite3 "$DB_FILE" << 'SQL'
CREATE TABLE invoices (
    id INTEGER PRIMARY KEY,
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
        # Basic data cleaning during import
        total = float(row['total_amount']) if row['total_amount'] else 0
        due = float(row['amount_due']) if row['amount_due'] else 0
        
        # Fix bad data (Negative equity)
        if due > total:
            due = total
            
        batch.append((
            row['id'], total, due,
            row['issue_date'], row['due_date'],
            row['paid_on_date'] if row['paid_on_date'] not in ['', 'NaT'] else None,
            row['payer_id']
        ))
        
        if len(batch) >= 1000:
            cursor.executemany('INSERT INTO invoices VALUES (?,?,?,?,?,?,?)', batch)
            batch = []

    if batch:
        cursor.executemany('INSERT INTO invoices VALUES (?,?,?,?,?,?,?)', batch)

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

conn.commit()
conn.close()
print("✓ Data imported successfully")
PYEOF

# Clean up temp files
rm -f month_analysis.tmp status_analysis.tmp payer_analysis.tmp payment_timing.tmp

# Step 4: Create Streamlit dashboard
echo "Step 4: Creating Streamlit dashboard..."

cat > "$DASHBOARD_FILE" << 'PYTHON'
import streamlit as st
import sqlite3
import pandas as pd
import plotly.express as px

st.set_page_config(page_title="Invoice Dashboard", layout="wide", page_icon="📊")

conn = sqlite3.connect('analysis.db', check_same_thread=False)

def load_data(query):
    return pd.read_sql_query(query, conn)

st.title("📊 Corrected Invoice Analysis")
st.markdown("---")

# 1. GLOBAL METRICS (Cash Basis)
invoices_df = load_data("SELECT total_amount, amount_due FROM invoices")
# Calculate Cash Collected per row
invoices_df['cash_collected'] = (invoices_df['total_amount'] - invoices_df['amount_due']).clip(lower=0)

total_invoiced = invoices_df['total_amount'].sum()
total_collected = invoices_df['cash_collected'].sum()
total_outstanding = invoices_df['amount_due'].sum()
count = len(invoices_df)

col1, col2, col3, col4 = st.columns(4)
col1.metric("Total Invoiced", f"${total_invoiced:,.0f}")
col2.metric("Cash Collected", f"${total_collected:,.0f}", delta=f"{(total_collected/total_invoiced*100):.1f}%")
col3.metric("Outstanding", f"${total_outstanding:,.0f}")
col4.metric("Total Invoices", f"{count:,}")

st.markdown("---")

col1, col2 = st.columns(2)

# 2. STATUS CHART & TABLE
with col1:
    st.subheader("💰 Cash Collection Status")
    status_data = load_data("SELECT * FROM payment_status")
    
    if not status_data.empty:
        # Chart
        fig = px.pie(status_data, values='total_amount', names='status', hole=0.4,
                     color_discrete_map={'Fully Paid':'#2ecc71', 'Partially Paid':'#f1c40f', 'Outstanding':'#e74c3c'})
        st.plotly_chart(fig, use_container_width=True)
        
        # Table (Restored)
        display_status = status_data.copy()
        display_status['total_amount'] = display_status['total_amount'].apply(lambda x: f"${x:,.0f}")
        display_status.columns = ["Status", "Count", "Amount"]
        st.dataframe(display_status, use_container_width=True, hide_index=True)

# 3. TIMING CHART & TABLE (With Unknown Category)
with col2:
    st.subheader("⏰ Timing Analysis (Cash Basis)")
    timing_data = load_data("SELECT * FROM payment_timing")
    
    if not timing_data.empty:
        # Chart
        fig = px.bar(timing_data, x='timing_status', y='total_amount', color='timing_status',
                     color_discrete_map={'On Time':'#27ae60', 'Late':'#e67e22', 'Unknown Date':'#95a5a6', 'Unpaid':'#c0392b'})
        st.plotly_chart(fig, use_container_width=True)
        
        # Table (Restored)
        display_timing = timing_data.copy()
        display_timing['total_amount'] = display_timing['total_amount'].apply(lambda x: f"${x:,.0f}")
        display_timing.columns = ["Timing", "Count", "Amount"]
        st.dataframe(display_timing, use_container_width=True, hide_index=True)

st.markdown("---")

# 4. FILTERED DATA TABLE
st.subheader("📋 Invoice Explorer")
col1, col2 = st.columns(2)
filter_type = col1.selectbox("Filter:", ["All Invoices", "Fully Paid Only", "Partially Paid", "Unpaid"])
search_id = col2.text_input("Payer Search:")

base_query = "SELECT * FROM invoices WHERE 1=1"
if filter_type == "Fully Paid Only":
    base_query += " AND amount_due = 0"
elif filter_type == "Partially Paid":
    base_query += " AND amount_due > 0 AND amount_due < total_amount"
elif filter_type == "Unpaid":
    base_query += " AND amount_due = total_amount"

if search_id:
    base_query += f" AND payer_id LIKE '%{search_id}%'"

df_filtered = load_data(base_query)

# Recalculate metrics for filtered view
if not df_filtered.empty:
    df_filtered['cash_paid'] = (df_filtered['total_amount'] - df_filtered['amount_due']).clip(lower=0)
    
    m1, m2, m3 = st.columns(3)
    m1.metric("Filtered Count", len(df_filtered))
    m2.metric("Filtered Total Value", f"${df_filtered['total_amount'].sum():,.0f}")
    m3.metric("Filtered Cash Collected", f"${df_filtered['cash_paid'].sum():,.0f}")
    
    # Format and Show Table
    display_df = df_filtered.copy()
    display_df['total_amount'] = display_df['total_amount'].apply(lambda x: f"${x:,.2f}")
    display_df['amount_due'] = display_df['amount_due'].apply(lambda x: f"${x:,.2f}")
    display_df['cash_paid'] = display_df['cash_paid'].apply(lambda x: f"${x:,.2f}")
    
    st.dataframe(display_df, use_container_width=True)
else:
    st.info("No matching records found.")

PYTHON

echo "=== Summary ==="
echo "✓ Script finished."
echo "✓ Tables restored for Status and Timing sections."
echo "✓ NaT dates are now handled as 'Unknown Date'."
echo "✓ Run dashboard: streamlit run $DASHBOARD_FILE"

# Auto-launch logic
read -p "Launch dashboard now? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    streamlit run "$DASHBOARD_FILE"
fi
