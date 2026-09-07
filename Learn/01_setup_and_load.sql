/* ============================================================
   OLIST — STAGE 0: SCHEMA + LOAD
   Run this top to bottom in MySQL Workbench.
   Requires MySQL 8.0+  ->  SELECT VERSION();
   ============================================================ */

/* ------------------------------------------------------------
   BEFORE YOU RUN ANYTHING — enable local file loading.

   1) In a Workbench query tab:
          SET GLOBAL local_infile = 1;

   2) Workbench blocks LOCAL INFILE on the client side too.
      Edit your connection:
          Database > Manage Connections > [your connection]
          > Advanced tab > "Others:" box, add this line:
              OPT_LOCAL_INFILE=1
      Then CLOSE and REOPEN the connection tab. This step is
      the one everybody misses.

   3) Paths below use forward slashes even on Windows.
      Change 'C:/olist/' to wherever you unzipped the Kaggle files.
   ------------------------------------------------------------ */

CREATE DATABASE IF NOT EXISTS olist
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;
USE olist;


/* ============================================================
   TABLES
   Note: timestamp columns are nullable. The CSVs contain empty
   strings for missing dates, which MySQL's strict mode rejects
   as DATETIME. We fix that at load time with NULLIF(@var,'').
   ============================================================ */

DROP TABLE IF EXISTS order_reviews, order_payments, order_items,
                     orders, customers, products, sellers,
                     category_translation;

CREATE TABLE customers (
  customer_id              CHAR(32)    NOT NULL PRIMARY KEY,
  customer_unique_id       CHAR(32)    NOT NULL,   -- <-- the REAL person
  customer_zip_code_prefix VARCHAR(8),
  customer_city            VARCHAR(64),
  customer_state           CHAR(2),
  KEY ix_cust_unique (customer_unique_id)
);

CREATE TABLE orders (
  order_id                      CHAR(32) NOT NULL PRIMARY KEY,
  customer_id                   CHAR(32) NOT NULL,
  order_status                  VARCHAR(20),
  order_purchase_timestamp      DATETIME NULL,
  order_approved_at             DATETIME NULL,
  order_delivered_carrier_date  DATETIME NULL,
  order_delivered_customer_date DATETIME NULL,
  order_estimated_delivery_date DATETIME NULL,
  KEY ix_ord_cust (customer_id),
  KEY ix_ord_purchase (order_purchase_timestamp)
);

CREATE TABLE order_items (
  order_id            CHAR(32) NOT NULL,
  order_item_id       INT      NOT NULL,
  product_id          CHAR(32),
  seller_id           CHAR(32),
  shipping_limit_date DATETIME NULL,
  price               DECIMAL(10,2),
  freight_value       DECIMAL(10,2),
  PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE order_payments (
  order_id             CHAR(32) NOT NULL,
  payment_sequential   INT      NOT NULL,
  payment_type         VARCHAR(20),
  payment_installments INT,
  payment_value        DECIMAL(10,2),
  PRIMARY KEY (order_id, payment_sequential)
);

/* No primary key here on purpose: review_id is NOT unique in this
   file, and a single order can have more than one review row. */
CREATE TABLE order_reviews (
  review_id              CHAR(32),
  order_id               CHAR(32),
  review_score           TINYINT,
  review_comment_title   VARCHAR(255),
  review_comment_message TEXT,
  review_creation_date   DATETIME NULL,
  review_answer_timestamp DATETIME NULL,
  KEY ix_rev_order (order_id)
);

CREATE TABLE products (
  product_id                 CHAR(32) NOT NULL PRIMARY KEY,
  product_category_name      VARCHAR(64),
  product_name_length        INT,   -- CSV header misspells this "lenght"
  product_description_length INT,   -- ditto
  product_photos_qty         INT,
  product_weight_g           INT,
  product_length_cm          INT,
  product_height_cm          INT,
  product_width_cm           INT
);

CREATE TABLE sellers (
  seller_id              CHAR(32) NOT NULL PRIMARY KEY,
  seller_zip_code_prefix VARCHAR(8),
  seller_city            VARCHAR(64),
  seller_state           CHAR(2)
);

CREATE TABLE category_translation (
  product_category_name         VARCHAR(64) NOT NULL PRIMARY KEY,
  product_category_name_english VARCHAR(64)
);


/* ============================================================
   LOAD
   If a load returns 0 rows or one giant mangled row, your line
   endings are Windows-style. Swap LINES TERMINATED BY '\n'
   for '\r\n' and rerun.
   ============================================================ */

LOAD DATA LOCAL INFILE 'C:/olist/olist_customers_dataset.csv'
INTO TABLE customers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(customer_id, customer_unique_id, customer_zip_code_prefix,
 customer_city, customer_state);


LOAD DATA LOCAL INFILE 'C:/olist/olist_orders_dataset.csv'
INTO TABLE orders
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, customer_id, order_status,
 @purchase, @approved, @carrier, @delivered, @estimated)
SET order_purchase_timestamp      = NULLIF(@purchase, ''),
    order_approved_at             = NULLIF(@approved, ''),
    order_delivered_carrier_date  = NULLIF(@carrier, ''),
    order_delivered_customer_date = NULLIF(@delivered, ''),
    order_estimated_delivery_date = NULLIF(@estimated, '');


LOAD DATA LOCAL INFILE 'C:/olist/olist_order_items_dataset.csv'
INTO TABLE order_items
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, order_item_id, product_id, seller_id,
 @shiplimit, price, freight_value)
SET shipping_limit_date = NULLIF(@shiplimit, '');


LOAD DATA LOCAL INFILE 'C:/olist/olist_order_payments_dataset.csv'
INTO TABLE order_payments
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, payment_sequential, payment_type,
 payment_installments, payment_value);


/* Review comments contain commas AND embedded newlines.
   FIELDS ENCLOSED BY '"' is what makes this work — don't drop it. */
LOAD DATA LOCAL INFILE 'C:/olist/olist_order_reviews_dataset.csv'
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


LOAD DATA LOCAL INFILE 'C:/olist/olist_products_dataset.csv'
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


LOAD DATA LOCAL INFILE 'C:/olist/olist_sellers_dataset.csv'
INTO TABLE sellers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(seller_id, seller_zip_code_prefix, seller_city, seller_state);


LOAD DATA LOCAL INFILE 'C:/olist/product_category_name_translation.csv'
INTO TABLE category_translation
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(product_category_name, product_category_name_english);

/* olist_geolocation_dataset.csv (1M rows) is not needed for any of
   the four deliverables. Skip it unless you want a map. */


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


/* ------------------------------------------------------------
   ORIENTATION QUERIES — run these before you analyse anything.
   Knowing the shape of your data is half the job.
   ------------------------------------------------------------ */

-- What date range am I actually working with?
SELECT MIN(order_purchase_timestamp) AS first_order,
       MAX(order_purchase_timestamp) AS last_order
FROM orders;
-- Expect ~Sep 2016 to Oct 2018. Note that Sep-Dec 2016 is nearly
-- empty (a handful of orders) and Oct 2018 is a partial month.
-- That is why the cohort script clips to 2017-01 .. 2018-08.

-- What statuses exist, and how common are they?
SELECT order_status, COUNT(*) n,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) pct
FROM orders GROUP BY order_status ORDER BY n DESC;
-- 'delivered' dominates. Notice how few orders sit in 'approved' —
-- that's why the funnel uses timestamps, not statuses.

-- THE BIG ONE: prove to yourself that customer_id is per-order.
SELECT COUNT(*)                          AS customer_rows,
       COUNT(DISTINCT customer_id)       AS distinct_customer_id,
       COUNT(DISTINCT customer_unique_id)AS distinct_people
FROM customers;
-- customer_id is unique per row (99,441). Real people: ~96,096.

-- How many people ever bought more than once?
SELECT orders_per_person, COUNT(*) AS people
FROM (
  SELECT c.customer_unique_id, COUNT(*) AS orders_per_person
  FROM orders o
  JOIN customers c ON c.customer_id = o.customer_id
  GROUP BY c.customer_unique_id
) x
GROUP BY orders_per_person
ORDER BY orders_per_person;
-- ~97% bought exactly once. Sit with this number — it drives
-- every conclusion in your memo.
