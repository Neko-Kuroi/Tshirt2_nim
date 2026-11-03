-- SQLAlchemy + Alembic 版が実際に作成したスキーマ(user_version=0)
CREATE TABLE alembic_version (
	version_num VARCHAR(32) NOT NULL, 
	CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num)
);
CREATE TABLE category (
	id INTEGER NOT NULL, 
	name VARCHAR(64) NOT NULL, 
	sort_order INTEGER NOT NULL, 
	uses_color BOOLEAN NOT NULL, 
	uses_size BOOLEAN NOT NULL, 
	uses_variant_name BOOLEAN NOT NULL, 
	is_printable BOOLEAN NOT NULL, 
	CONSTRAINT pk_category PRIMARY KEY (id), 
	CONSTRAINT uq_category_name UNIQUE (name)
);
CREATE TABLE design (
	id INTEGER NOT NULL, 
	name VARCHAR(128) NOT NULL, 
	note TEXT NOT NULL, 
	CONSTRAINT pk_design PRIMARY KEY (id), 
	CONSTRAINT uq_design_name UNIQUE (name)
);
CREATE TABLE user (
	id INTEGER NOT NULL, 
	username VARCHAR(64) NOT NULL, 
	password_hash VARCHAR(256) NOT NULL, 
	role VARCHAR(16) NOT NULL, 
	is_active BOOLEAN NOT NULL, 
	created_at DATETIME NOT NULL, 
	CONSTRAINT pk_user PRIMARY KEY (id), 
	CONSTRAINT uq_user_username UNIQUE (username)
);
CREATE TABLE item (
	id INTEGER NOT NULL, 
	category_id INTEGER NOT NULL, 
	brand VARCHAR(64) NOT NULL, 
	item_no VARCHAR(64) NOT NULL, 
	name VARCHAR(128) NOT NULL, 
	note TEXT NOT NULL, 
	is_active BOOLEAN NOT NULL, 
	CONSTRAINT pk_item PRIMARY KEY (id), 
	CONSTRAINT fk_item_category_id_category FOREIGN KEY(category_id) REFERENCES category (id), 
	CONSTRAINT uq_item_category_id UNIQUE (category_id, brand, item_no)
);
CREATE TABLE variant (
	id INTEGER NOT NULL, 
	item_id INTEGER NOT NULL, 
	color VARCHAR(64) NOT NULL, 
	size VARCHAR(32) NOT NULL, 
	variant_name VARCHAR(64) NOT NULL, 
	quantity INTEGER NOT NULL, 
	updated_at DATETIME NOT NULL, 
	CONSTRAINT pk_variant PRIMARY KEY (id), 
	CONSTRAINT ck_variant_qty_nonneg CHECK (quantity >= 0), 
	CONSTRAINT fk_variant_item_id_item FOREIGN KEY(item_id) REFERENCES item (id), 
	CONSTRAINT uq_variant_item_id UNIQUE (item_id, color, size, variant_name)
);
CREATE TABLE printed_product (
	id INTEGER NOT NULL, 
	design_id INTEGER NOT NULL, 
	variant_id INTEGER NOT NULL, 
	quantity INTEGER NOT NULL, 
	updated_at DATETIME NOT NULL, 
	CONSTRAINT pk_printed_product PRIMARY KEY (id), 
	CONSTRAINT ck_printed_product_qty_nonneg CHECK (quantity >= 0), 
	CONSTRAINT fk_printed_product_design_id_design FOREIGN KEY(design_id) REFERENCES design (id), 
	CONSTRAINT fk_printed_product_variant_id_variant FOREIGN KEY(variant_id) REFERENCES variant (id), 
	CONSTRAINT uq_printed_product_design_id UNIQUE (design_id, variant_id)
);
CREATE TABLE stock_movement (
	id INTEGER NOT NULL, 
	batch_id VARCHAR(36) NOT NULL, 
	kind VARCHAR(16) NOT NULL, 
	variant_id INTEGER, 
	printed_product_id INTEGER, 
	delta INTEGER NOT NULL, 
	note TEXT NOT NULL, 
	user_id INTEGER NOT NULL, 
	created_at DATETIME NOT NULL, 
	CONSTRAINT pk_stock_movement PRIMARY KEY (id), 
	CONSTRAINT ck_stock_movement_one_target CHECK ((variant_id IS NULL) <> (printed_product_id IS NULL)), 
	CONSTRAINT ck_stock_movement_delta_nonzero CHECK (delta <> 0), 
	CONSTRAINT fk_stock_movement_printed_product_id_printed_product FOREIGN KEY(printed_product_id) REFERENCES printed_product (id), 
	CONSTRAINT fk_stock_movement_user_id_user FOREIGN KEY(user_id) REFERENCES user (id), 
	CONSTRAINT fk_stock_movement_variant_id_variant FOREIGN KEY(variant_id) REFERENCES variant (id)
);
CREATE INDEX ix_stock_movement_batch_id ON stock_movement (batch_id);
CREATE INDEX ix_stock_movement_created_at ON stock_movement (created_at);
