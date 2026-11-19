-- nothing sells above MRP and no refund is bigger than what was paid
select order_item_id, mrp, selling_price, line_amount, refund_amount
from {{ ref('fct_order_items') }}
where selling_price > mrp
   or refund_amount > line_amount
