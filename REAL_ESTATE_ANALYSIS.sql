-- ============================================================================
-- REAL ESTATE MARKET & TRANSACTION ANALYSIS
-- Comprehensive SQL Case Study (MySQL)
-- ============================================================================


-- ============================================================================
-- STAGE 1: DATA EXPLORATION & QUALITY ASSESSMENT
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Q1: Evaluate completeness — total record counts per table
-- ---------------------------------------------------------------------------
-- WHAT THIS DOES: counts rows in each table. If a table has way fewer rows
-- than expected, that's a red flag for incomplete data collection.


select 'Property_transactions' as table_name  , count(*) as Total_Records
from property_transactions 

union all 

select 'Agents' , count(*) 
from agents 

union all 

select 'Market_Trends' , count(*)
from market_trends;


-- Classify undefined property types as 'Other' instead of leaving them NULL

select case 
	when type is null or type ='' then 'Other' else type end as property_types,
    count(*) as total_listings
from Property_transactions
group by 1 
order by total_listings;

-- Check that every transaction has a valid (non-null) property ID
select count(*) as records_with_missing_property_id
from Property_transactions
where property_id is null;


-- ---------------------------------------------------------------------------
-- Q2: Missing value percentage in key fields
-- ---------------------------------------------------------------------------
-- WHAT THIS DOES: for each important column, calculates what % of rows
-- are NULL. Formula = (count of NULLs / total rows) * 100

select 
	'Listing_Price' as Column_Name,
	round(sum(case when Listing_Price is null then 1 else 0 end )*100.0
		/count(*),2) as Missing_Values_Percentage
from Property_transactions	

union all

select 	
	'Type'  ,
	round(sum(case when Type is null or type ='' then 1 else 0 end )*100.0
		/count(*),2) 

from Property_transactions

union all 

select 
	'Size_SqFt',
	round(sum(case when Size_SqFt is null  then 1 else 0  end )*100.0
		/count(*),2)
from Property_transactions;


-- ---------------------------------------------------------------------------
-- Q3: Duplicates, extreme prices, unrealistic sizes
-- ---------------------------------------------------------------------------
select count(*) as Duplicate_Records
from (
	select property_id,Year_Built,Listing_Price,count(*) as cnt 
	from Property_transactions
	group by property_id,Year_Built,Listing_Price
	having count(*)>1
) as dup;


-- 3b. Extreme pricing values — top 1% (99th percentile) using NTILE
-- NTILE(100) splits all rows into 100 equal-sized buckets ordered by price.
-- Bucket 100 = the top 1% of prices.

with price_buckets as (
	select 
		property_id,Listing_Price as sale_price,
		neighborhood,
		NTILE(100) over ( order by Listing_Price) as price_bucket
	from Property_transactions
	where property_id is not null 
)

select property_id,sale_price,neighborhood
from price_buckets
where price_bucket =100     -- top 1%  
	or sale_price<=0        -- also flag negative/zero prices
order by sale_price desc ;

-- ---------------------------------------------------------------------------
-- 3c: Flag unrealistic property sizes
-- ---------------------------------------------------------------------------
-- Step 1: Validation check
-- Identify properties with unusually large sizes. For this dataset,
-- I applied a threshold of 4500 sqft as a practical benchmark to highlight potential outliers.

select property_id,size_sqft,neighborhood, 'Unusually Large' AS Issue
from property_transactions 
where Size_SqFt >= 4500
order by Size_SqFt desc;


-- ============================================================================
-- STAGE 2: DATA CLEANING & INTEGRITY MANAGEMENT
-- ============================================================================
SET SQL_SAFE_UPDATES = 0;
-- ---------------------------------------------------------------------------
-- Q0: Handle missing values in TYPE column
-- ---------------------------------------------------------------------------
-- Detect blanks (NULL or empty string) in the 'type' column and fill them
-- with a default label 'Unknown' to ensure consistency.
-- This prevents blank partitions when computing medians or grouping later.

update property_transactions 
set type ='Unknown'
where type is null or type ='';

-- Verify
select count(*) as filled_type_count
from property_transactions
where type ='Unknown';

-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Q1: Impute missing transaction prices and property sizes
-- ---------------------------------------------------------------------------
-- Note: In this dataset, there were no missing values in listing_price or Size_SqFt.
-- The following workflow is included as a reusable template to demonstrate
-- how I would handle missing data in real-world projects.

-- 1a. Impute missing listing_price using the MEDIAN of similar properties
-- (same city + property_type  

with ranked_prices as (
	select city,type,listing_price,
	ROW_NUMBER() over ( partition by city,type order by Listing_Price ) as rn,
	count(*) over ( partition by city,type ) as total_cnt
	from property_transactions
	where Listing_Price is not null
),
 median_by_group as (
	select city,type,avg(Listing_Price) as median_price
	from ranked_prices
	where rn in (FLOOR((total_cnt +1 ) /2) , CEIL((total_cnt +1)/2))
	group by city,type
)
update Property_transactions pt 
join median_by_group m 
	on pt.city = m.city and 
	pt.type = m.type
set pt.Listing_Price = m.median_price
where Listing_Price is null ;

	
-- 1b. Impute missing size_sqft using the MEAN size for same property_type + city

update Property_transactions pt 
join(
	select city,type,avg(size_sqft) as avg_size
	from property_transactions 
	where size_sqft is not null 
	group by city, type 
)ref 
set pt.Size_SqFt  = ref.avg_size
where size_sqft is null ;

-- ---------------------------------------------------------------------------
-- Q2: Remove duplicates based on Property_ID + Listing_Price + Neighborhood
-- ---------------------------------------------------------------------------
-- Step 1: Validation check
-- Verify if any duplicates exist using GROUP BY + HAVING.
-- Note: In this dataset, no duplicates were found (query returned zero rows).
-- The following workflow is included as a reusable template for real-world projects

select count(*) as duplicated_rows
from (
	select property_id,city,type, count(*) as cnt
	from property_transactions
	group by property_id, city,type
	having count(*) > 1
) dup;

-- Step 2: Deduplication workflow (template)
-- Uses ROW_NUMBER() to mark each row in a duplicate group.
-- Keeps row #1, deletes the rest.

delete pt from property_transactions pt 
join(
	select property_id,ROW_NUMBER() over ( partition by property_id,Listing_Price,neighborhood 
	order by property_id) as rn 
	from property_transactions
) rk 
	on pt.Property_ID = rk.property_id
where rk.rn>1;

-- Verify
select count(*) as records_after_dedup 
from property_transactions;

-- ---------------------------------------------------------------------------
-- Q3: Correct extreme values in Listing_Price
-- ---------------------------------------------------------------------------
-- Step 1: Validation check
-- Verify if any transactions have Listing_Price <= 0.
-- Note: In this dataset, validation confirmed zero records matched this condition.
-- The following workflow is included as a reusable template for real-world projects

select *  FROM property_transactions
WHERE listing_price <= 0;


-- Step 2: Removal workflow (template)
-- Deletes transactions where Listing_Price is negative or zero.

delete from property_transactions
where Listing_Price <=0;

-- 3b. Cap excessively high prices at the 99th percentile PER CITY
--  using NTILE(100) 

with city_buckets as (
	select property_id,city,Listing_Price,
	NTILE(100) over ( partition by city order by listing_price ) as bucket
	from Property_transactions
),
city_cap as (
	select city,min(listing_price) as cap_price
	from city_buckets
	where Bucket =100
	group by city
)
update property_transactions pt
join city_cap cc on pt.city = cc.city
set pt.listing_price = cc.cap_price
where pt.listing_price > cc.cap_price;


-- ============================================================================
-- STAGE 3: MARKET TRENDS & PRICING ANALYSIS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Q1: Average listing price per city per year + year-on-year % change
-- ----------------------------------------------------------------------------
-- Note: The dataset contains property records from 1950 onwards.
-- For this analysis, I restricted the scope to 2019–2022 to highlight
-- recent market trends and compute year-on-year changes in a relevant window.

with yearly_avg as (
	select Year_Built as year, city,round(avg(Listing_Price),2) as Avg_Listing_Price
	from property_transactions
	where year_built  between 2019 and 2022
	group by Year_Built,city
)
select 
	year,city,Avg_Listing_Price,
	round((Avg_Listing_Price - lag(Avg_Listing_Price) over ( partition by city  order by year))
	/ lag(Avg_Listing_Price) over ( partition by city order by year )*100.0,2) as Percent_Change
from yearly_avg
order by city,year;

-- -----------------------------------------------------------------------------
-- Q2: Highest / lowest property values by year + city, and YoY price moves
-- -----------------------------------------------------------------------------
-- Scope restricted to 2019–2022 for consistency with Q1

with city_year_avg as (
	select Year_Built as year ,city,round(avg(listing_price),2) as Current_Price
	from property_transactions
	where year_built  between 2019 and 2022
	group by Year_Built, city
)
select 
	year,city,Current_Price,
	round((Current_Price - lag(Current_Price) over ( partition by city order by year))
	/lag(Current_Price) over ( partition by city order by year)*100.0,2) as Price_Change_Percentage
from city_year_avg
order by city,year;

-- 2b. Which year/city had the single highest and lowest average price 
-- Scope restricted to 2019–2022 for consistency with Q1

with city_year_avg as (	
	select Year_Built as year , city ,
	avg(listing_price) as avg_price
	from Property_transactions
	where year_built between 2019 and 2022
	group by Year_Built , city
),
ranked as (
	select *,
		rank() over ( order by avg_price desc) as rank_high,
		rank() over (order by avg_price asc ) as rank_low
	from city_year_avg 
)
select 'Highest Property Values' as Property_Values,year,city
from ranked 
where rank_high = 1

union all 

select 'Lowest Property Values' , year,city
from ranked 
where rank_low = 1;


-- ---------------------------------------------------------------------------
-- Q3: Average listing price by property type
-- ---------------------------------------------------------------------------

select type,round(avg(listing_price),2) as Avg_Listing_Price
from property_transactions
group by type 
order by Avg_Listing_Price desc;

-- ---------------------------------------------------------------------------
-- Q4: Most frequently listed property types per city (listing volume)
-- ---------------------------------------------------------------------------

select type,city,count(*) as Listings_Count
from Property_transactions 
group by type,city
order by Listings_Count desc;

-- ---------------------------------------------------------------------------
-- Q5: Interest rate impact on property prices
-- ---------------------------------------------------------------------------
-- This examines how changes in interest rates align with 
-- average property prices, highlighting percentage shifts across 
-- different rate levels.

with rate_price as (
	select mt.interest_rate as Interest_Rate , round(avg(listing_price),2) as Average_Listing_Price
	from property_transactions  pt 
	join market_trends mt 
	on pt.city = mt.city and pt.Year_Built = mt.year
	group by mt.interest_rate
)
select
	Interest_Rate,Average_Listing_Price,
	round((Average_Listing_Price - lag(Average_Listing_Price) over ( order by Interest_rate))
	/ lag(Average_Listing_Price) over ( order by Interest_Rate)*100.0, 2 ) Percent_Change
from rate_price
order by Interest_Rate;


-- ============================================================================
-- STAGE 4: BUYER BEHAVIOR & INVESTMENT PATTERNS
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Q1: Cities with strongest housing demand + typical home/rent prices
-- ---------------------------------------------------------------------------
-- Note: The dataset contains property records from 1950 onwards.
-- For this analysis, I restricted the scope to a snapshot year (2022)
-- to highlight the most recent market dynamics. This ensures the output
-- reflects current demand and affordability conditions.

select 
	city as City,
	round(Housing_Demand_Index)as Highest_Demand_Index,
	round(Avg_Home_Price,2) as Avg_Typical_Home_Price,
	round(Avg_Rent_Price,2) as Avg_Typical_Rent_Price
from market_trends 
where year = 2022
order by Highest_Demand_Index desc
limit 10;

-- ---------------------------------------------------------------------------
-- Q2: Distribution of property sizes by property type
-- ---------------------------------------------------------------------------
-- This calculates the average property size (sqft) for each 
-- property type to compare typical size distributions across categories.


select 
	type as property_type,
	round(avg(Size_SqFt),2) as Avg_Size_SqFt
from property_transactions
group by type
order by Avg_Size_SqFt desc;


-- ============================================================================
-- STAGE 5: HOUSING SUPPLY & MARKET COMPETITIVENESS
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Q1: Years with the highest number of new property developments
-- ---------------------------------------------------------------------------
-- This analysis counts new properties built per year to highlight
-- construction trends and identify periods of high development activity.


select 
	year_built as year ,
	count(*) as New_Properties_Built
from property_transactions
group by year_built
order by year;

-- ---------------------------------------------------------------------------
-- 1b: Highest and lowest construction years
-- ---------------------------------------------------------------------------
-- This identifies the peak and trough years of new property
-- development by comparing maximum and minimum construction counts.


WITH yearly_count AS (
    SELECT year_built, COUNT(*) AS cnt
    FROM property_transactions
    WHERE year_built IS NOT NULL
    GROUP BY year_built
)
SELECT 'Highest New_Property' AS Category, year_built AS Year
FROM (
	select year_built,cnt
	from yearly_count
	order by cnt desc 
	limit 1
) as high 

UNION ALL

SELECT 'Lowest New_Property', year_built
FROM (
	select year_built,cnt
	from yearly_count
	order by cnt asc 
	limit 1
) as low;

-- ---------------------------------------------------------------------------
-- Q2: Cities with the most new construction
-- ---------------------------------------------------------------------------
-- This analysis counts new properties built per city and ranks them
-- to identify where construction activity is highest.

select 
	city as City ,
	count(*) as New_Property_Built
from property_transactions
group by city
order by New_Property_Built desc;


-- ---------------------------------------------------------------------------
-- Q3: Does new construction stabilize prices? (supply vs price by year)
-- ---------------------------------------------------------------------------
-- This analysis compares annual new property construction counts with
-- average home prices to explore whether increased supply correlates
-- with price stabilization.

with supply as (
	select 
		year_built as year , 
		count(*) as New_Properties_Built
	from property_transactions
	group by year_built 
),prices as (
	select year_built as year ,
	round(avg(Listing_Price),2) as Avg_Home_Price
	from property_transactions 
	group by year_built
)
select s.Year, s.New_Properties_Built, p.Avg_Home_Price
from supply s 
join prices p 
on s.year = p.year
order by s.year;

-- ---------------------------------------------------------------------------
-- Q4: Cities with the highest changes in investor activity
-- ---------------------------------------------------------------------------
-- This analysis measures volatility in investor activity by calculating
-- the range (MAX - MIN) of Investor Activity Score per city. Cities with
-- larger ranges indicate stronger fluctuations in investor engagement.

select 
	city,
	round(max(Investor_Activity_Score) - min(Investor_Activity_Score),2) as Investor_Activity_Change 
from market_trends 
group by city 
having round(max(Investor_Activity_Score) - min(Investor_Activity_Score),2) >0
order by Investor_Activity_Change desc ;


-- ============================================================================
-- STAGE 6: BUYER SEGMENTATION & AFFORDABILITY CHALLENGES
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Q1: Which buyer segments are most active + YoY trends 
-- ---------------------------------------------------------------------------
-- No buyer_type column exists in the dataset.
-- Using Investor_Activity_Score as a proxy for investor activity and
-- Affordability_Change_YoY to track affordability shifts year over year.

with investor_trend as (
	select city,year,
		round(Investor_Activity_Score,2) as Investor_Activity,
		round(Affordability_Change_YoY,2) as Affordability_Change
	from market_trends 
)
select city,year,
	Investor_Activity,Affordability_Change,
	round(Investor_Activity - lag(Investor_Activity) 
	over( partition by city order by year),2) as YoY_Investor_Change
from investor_trend
order by city,year;

-- ---------------------------------------------------------------------------
-- Q2: Which income brackets face the most affordability challenges?
-- ---------------------------------------------------------------------------
-- This analysis compares home prices to household income using the 
-- Price-to-Income Ratio, classifying brackets from 'Very Affordable' 
-- to 'Severely Unaffordable'.

with bracket_ratio as(
	select Income_Bracket,
		round(avg(Affordability_Price_to_Income_Ratio),2) as Price_To_Income_Ratio,
		round(avg(Affordability_Median_Household_Income),2) as Avg_Median_Income,
		round(avg(Affordability_Avg_Home_Price),2) as Avg_Home_Price
	from market_trends 
	group by Income_Bracket
)
select Income_Bracket,
	Price_To_Income_Ratio,Avg_Median_Income,Avg_Home_Price,
	case 
	when Price_To_Income_Ratio >=6 then 'Severely Unaffordable'
	when Price_To_Income_Ratio >=4 then 'Moderately Unaffordable'
	when Price_To_Income_Ratio >=2 then 'Affordable'
	else 'Very Affordable'
	end as Affordability_Stress
from bracket_ratio
order by Price_To_Income_Ratio desc ;

-- ---------------------------------------------------------------------------
-- Q3: Rank cities by investor activity
-- ---------------------------------------------------------------------------
-- This analysis calculates the average Investor Activity Score per city
-- and ranks them from highest to lowest to highlight where investor
-- engagement is strongest.

with city_investor as (
	select city as City ,
		round(avg(Investor_Activity_Score),2) as Avg_Investor_Activity
	from market_trends
	group by city 
)
select City,Avg_Investor_Activity,
	rank() over ( order by Avg_Investor_Activity desc) as Investor_Rank
from city_investor
order by Investor_Rank;