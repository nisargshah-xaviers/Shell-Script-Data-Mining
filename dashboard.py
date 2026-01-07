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

