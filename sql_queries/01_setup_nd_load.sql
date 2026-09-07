SELECT VERSION();

SET GLOBAL local_infile = 1;
SELECT @@GLOBAL.local_infile;   -- must return 1
create database if  not exists olist;
use olist;

create table customers (
	customer_id char(32) not null primary key,
    customer_unique_id char(32) not null, -- not real person,
    customer_zip_code_prefix varchar(8),
    customer_city varchar(64),
    customer_state char(2),
    key ix_cust_unique(customer_unique_id)
);

create table orders (
	order_id char(32) not null primary key,
    customer_id char(32) not null,
    order_status varchar(20),
    order_purchase_timestamp datetime null,
    order_approved_at datetime null,
    order_delivered_carrier_date datetime null,
    order_delivered_customer_date datetime null,
    order_estimated_delivery_date datetime null,
    key ix_ord_cust (customer_id),
    key ix_ord_purchase(order_purchase_timestamp)
);

create table order_items (
	order_id char(32) not null,
    order_item_id int not null,
    product_id char(32),
    seller_id char(32),
    shipping_limit_date datetime null,
    price decimal(10,2),
    freight_value decimal(10,2),
    primary key (order_id, order_item_id)
);

create table order_payments (
	order_id char(32) not null,
    payment_sequential int not null,
    payment_type varchar(20),
    payment_installments int,
    payment_value decimal(10,2),
    primary key (order_id ,payment_sequential)
);

-- No primary key here on purpose: review_id is NOT unique in this
-- file, and a single order can have more than one review row.
create table order_reviews (
	review_id char(32),
    order_id char(32),
    review_score tinyint,
    review_comment_title varchar(255),
    review_comment_message text,
    review_creation_date datetime null,
    review_answer_timestamp datetime null,
    key ix_rev_order (order_id)
);

create table products (
	product_id char(32) not null primary key,
    product_category_name varchar(64),
    product_name_length int, -- CSV header misspells this 'lenght'
    product_description_lenght int , -- ditto
    product_photos_qty int,
    product_weight_g int,
    product_length_cm int,
    product_height_cm int,
    product_width_cm int
);

create table sellers (
	seller_id char(32) not null primary key,
    seller_zip_code_prefix varchar(8),
    seller_city varchar(64),
    seller_state char(2)
);

create table category_translation (
	product_category_name varchar(64) not null primary key,
    product_category_name_engilsh varchar(64)
);

load data local infile "E:/DA/olist-customer-retention-analysis/Raw Data/olist_customers_dataset.csv"
into table customers
character set utf8mb4
fields terminated by ',' enclosed by '"'
lines terminated by '\n'
ignore 1 lines
(customer_id, customer_unique_id, customer_zip_code_prefix,
 customer_city, customer_state);
 
load data local infile "E:/DA/olist-customer-retention-analysis/Raw Data/olist_orders_dataset.csv"
into table orders
character set utf8mb4
fields terminated by ',' enclosed by '"'
lines terminated by '\n'
ignore 1 lines
(order_id, customer_id, order_status,
 @purchase, @approved, @carrier, @delivered, @estimated)
SET order_purchase_timestamp      = NULLIF(@purchase, ''),
    order_approved_at             = NULLIF(@approved, ''),
    order_delivered_carrier_date  = NULLIF(@carrier, ''),
    order_delivered_customer_date = NULLIF(@delivered, ''),
    order_estimated_delivery_date = NULLIF(@estimated, '');

select count(*) from orders;

LOAD DATA LOCAL INFILE 'E:/DA/olist-customer-retention-analysis/Raw Data/olist_order_items_dataset.csv'
INTO TABLE order_items
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, order_item_id, product_id, seller_id,
 @shiplimit, price, freight_value)
SET shipping_limit_date = NULLIF(@shiplimit, '');


LOAD DATA LOCAL INFILE 'E:/DA/olist-customer-retention-analysis/Raw Data/olist_order_payments_dataset.csv'
INTO TABLE order_payments
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, payment_sequential, payment_type,
 payment_installments, payment_value);


/* Review comments contain commas AND embedded newlines.
   FIELDS ENCLOSED BY '"' is what makes this work — don't drop it. */
LOAD DATA LOCAL INFILE 'E:/DA/olist-customer-retention-analysis/Raw Data/olist_order_reviews_dataset.csv'
INTO TABLE order_reviews
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(review_id, order_id, review_score,
 @title, @msg, @created, @answered)
SET review_comment_title    = NULLIF(@title, ''),
    review_comment_message  = NULLIF(@msg, ''),
    review_creation_date    = NULLIF(@created, ''),
    review_answer_timestamp = NULLIF(@answered, '');


LOAD DATA LOCAL INFILE 'E:/DA/olist-customer-retention-analysis/Raw Data/olist_products_dataset.csv'
INTO TABLE products
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(product_id, @cat, @namelen, @desclen, @photos,
 @weight, @len, @height, @width)
SET product_category_name      = NULLIF(@cat, ''),
    product_name_length        = NULLIF(@namelen, ''),
    product_description_length = NULLIF(@desclen, ''),
    product_photos_qty         = NULLIF(@photos, ''),
    product_weight_g           = NULLIF(@weight, ''),
    product_length_cm          = NULLIF(@len, ''),
    product_height_cm          = NULLIF(@height, ''),
    product_width_cm           = NULLIF(@width, '');

LOAD DATA LOCAL INFILE 'E:/DA/olist-customer-retention-analysis/Raw Data/olist_sellers_dataset.csv'
INTO TABLE sellers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(seller_id, seller_zip_code_prefix, seller_city, seller_state);


LOAD DATA LOCAL INFILE 'E:/DA/olist-customer-retention-analysis/Raw Data/product_category_name_translation.csv'
INTO TABLE category_translation
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(product_category_name, product_category_name_english);

/* olist_geolocation_dataset.csv (1M rows) is not needed for any of
   the four deliverables. Skip it unless you want a map. */
CREATE TABLE geolocation (
  geolocation_zip_code_prefix VARCHAR(8),
  geolocation_lat             DECIMAL(11,8),
  geolocation_lng             DECIMAL(11,8),
  geolocation_city            VARCHAR(64),
  geolocation_state           CHAR(2),
  KEY ix_geo_zip (geolocation_zip_code_prefix)
);

LOAD DATA LOCAL INFILE 'E:/DA/olist-customer-retention-analysis/Raw Data/olist_geolocation_dataset.csv'
INTO TABLE geolocation
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(geolocation_zip_code_prefix, geolocation_lat, geolocation_lng,
 geolocation_city, geolocation_state);
/* ============================================================
   VALIDATION — run this and compare. If a number is off,
   fix the load before writing a single line of analysis.
   ============================================================ */

SELECT 'customers'   t, COUNT(*) rows_loaded, 99441  AS expected FROM customers
UNION ALL SELECT 'orders',        COUNT(*), 99441  FROM orders
UNION ALL SELECT 'order_items',   COUNT(*), 112650 FROM order_items
UNION ALL SELECT 'order_payments',COUNT(*), 103886 FROM order_payments
UNION ALL SELECT 'order_reviews', COUNT(*), 99224  FROM order_reviews
UNION ALL SELECT 'products',      COUNT(*), 32951  FROM products
UNION ALL SELECT 'sellers',       COUNT(*), 3095   FROM sellers
UNION ALL SELECT 'category_translation', COUNT(*), 71 FROM category_translation;
select count(*) from geolocation;