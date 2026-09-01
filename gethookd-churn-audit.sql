-- GetHookd churn-by-plan audit queries
-- Prepared 2026-08-31 from a read-only Stripe API reconstruction.
--
-- Stripe Sigma schema note:
--   This file uses invoice_line_items.plan_id, the common Sigma name for the
--   Stripe Price/legacy Plan identifier. If this account exposes price_id
--   instead, replace every ili.plan_id reference in Queries A and C with
--   ili.price_id.
--
-- All TIMESTAMP literals below are UTC. Windows are half-open [start, end).


-- ============================================================================
-- QUERY A: FIXED START-COHORT METRICS
-- ============================================================================
-- Produces, per starting tier and in a deduplicated all-tier total:
--   1. gross subscription ends / paid subscriptions at start;
--   2. tier exits / paid subscriptions at start;
--   3. event-based canonical-monthly logo loss;
--   4. point-in-time canonical-monthly paid-service loss.
--
-- Boundary membership requires a positive paid recurring invoice line whose
-- service period covers that boundary. Recurring price lines belonging to the
-- explicit plan-product scope are ranked before the four exact core prices are
-- joined. This prevents both of these errors:
--   * an unrelated recurring add-on outranking the tier;
--   * an older canonical price hiding a newer non-core price on a tier product.

WITH
windows (
  window_key,
  window_days,
  start_at,
  end_at
) AS (
  VALUES
    (
      '30d',
      30,
      TIMESTAMP '2026-08-01 11:47:21',
      TIMESTAMP '2026-08-31 11:47:21'
    ),
    (
      '120d',
      120,
      TIMESTAMP '2026-05-03 11:47:21',
      TIMESTAMP '2026-08-31 11:47:21'
    )
),

price_map (
  price_id,
  tier_name,
  tier_order
) AS (
  VALUES
    ('price_1TEsavLnfBBzdwXDdu5OJYuB', 'Starter ($29/month)', 1),
    ('price_1TEseyLnfBBzdwXDH1RcdZ4e', 'Pro ($49/month)',     2),
    ('price_1TEshlLnfBBzdwXDvx4og8u2', 'Team ($79/month)',   3),
    ('price_1TEsn9LnfBBzdwXDFSJEiV43', 'Agency ($129/month)', 4)
),

-- Detection/ranking scope: known canonical monthly, alternate, annual, and
-- historical plan products. Only the four exact monthly prices are in
-- price_map. Other plan products can win the temporal rank but resolve to NULL
-- as a monthly-portfolio exit. Unrelated recurring add-ons remain out.
tier_products (
  product_id
) AS (
  VALUES
    ('prod_UDJDtFxubsIPoy'),
    ('prod_UDJHllai95Kctx'),
    ('prod_UDJK8joVZdKA2v'),
    ('prod_UDJPq8QO3CSEqw'),
    ('prod_V1TMh6R6BurXyK'),
    ('prod_V1TMwh6fY22bRz'),
    ('prod_V18RAT8yxl306P'),
    ('prod_UDJEb3IVCo8YwS'),
    ('prod_UDJI7cHycrzzXv'),
    ('prod_UDJOwzRHZDvbSj'),
    ('prod_UDJR22dmPhY9xz'),
    ('prod_Q7Joa1kkMcB1gk'),
    ('prod_Q7JqaK1458BEIf'),
    ('prod_SthqEojqp9ZxwW'),
    ('prod_StiB20a4BX7lCn'),
    ('prod_StiRvbIyc1ILw4'),
    ('prod_TY1QdobsRqfrnY'),
    ('prod_Tc6fMOFljdu4tu'),
    ('prod_Tc6vzeJE3vmtLQ'),
    ('prod_RQDh61VAmeLbS6'),
    ('prod_RGVC1NUzm3BnPY'),
    ('prod_RGVE3jAEvadqbw'),
    ('prod_RGVI00SezdDn0z'),
    ('prod_Qi1iL0E4TC4PFO'),
    ('prod_RGVKY6YQxMcVro'),
    ('prod_Qi1l4RkKllNNnS'),
    ('prod_TRkdcRzTLMane8'),
    ('prod_StiGimjMKy4dHh'),
    ('prod_Sti47zaxNhfOC9'),
    ('prod_TY1XCKtE7vhSsq'),
    ('prod_Tc70WdTtS5LKRb'),
    ('prod_StiVEPEDQ0Cijr'),
    ('prod_SUU91xIS11CA5S')
),

paid_recurring_exposures AS (
  SELECT
    i.subscription_id,
    s.customer_id,
    ili.id AS invoice_line_id,
    i.id AS invoice_id,
    ili.plan_id AS price_id,
    pr.product_id,
    COALESCE(i.status_transitions_paid_at, i.date) AS paid_at,
    ili.period_start,
    ili.period_end,
    s.created AS subscription_created,
    s.ended_at
  FROM invoices i
  INNER JOIN invoice_line_items ili
    ON ili.invoice_id = i.id
  INNER JOIN prices pr
    ON pr.id = ili.plan_id
  INNER JOIN tier_products tp
    ON tp.product_id = pr.product_id
  INNER JOIN subscriptions s
    ON s.id = i.subscription_id
  WHERE i.subscription_id IS NOT NULL
    AND i.status = 'paid'
    AND COALESCE(i.amount_paid, 0) > 0
    AND ili.type = 'subscription'
    AND COALESCE(ili.amount, 0) > 0
    AND ili.period_end > ili.period_start
),

start_ranked AS (
  SELECT
    w.window_key,
    w.window_days,
    w.start_at,
    w.end_at,
    pe.*,
    ROW_NUMBER() OVER (
      PARTITION BY
        w.window_key,
        pe.subscription_id
      ORDER BY
        pe.paid_at DESC,
        pe.period_start DESC,
        pe.period_end DESC,
        pe.invoice_id DESC,
        pe.invoice_line_id DESC
    ) AS exposure_rank
  FROM windows w
  INNER JOIN paid_recurring_exposures pe
    ON pe.paid_at < w.start_at
   AND pe.period_start <= w.start_at
   AND pe.period_end > w.start_at
  WHERE pe.subscription_created < w.start_at
    AND (
      pe.ended_at IS NULL
      OR pe.ended_at > w.start_at
    )
),

start_base AS (
  SELECT
    sr.window_key,
    sr.window_days,
    sr.start_at,
    sr.end_at,
    sr.subscription_id,
    sr.customer_id,
    sr.price_id,
    sr.ended_at,
    pm.tier_name,
    pm.tier_order
  FROM start_ranked sr
  INNER JOIN price_map pm
    ON pm.price_id = sr.price_id
  WHERE sr.exposure_rank = 1
),

end_ranked AS (
  SELECT
    w.window_key,
    w.window_days,
    w.start_at,
    w.end_at,
    pe.*,
    ROW_NUMBER() OVER (
      PARTITION BY
        w.window_key,
        pe.subscription_id
      ORDER BY
        pe.paid_at DESC,
        pe.period_start DESC,
        pe.period_end DESC,
        pe.invoice_id DESC,
        pe.invoice_line_id DESC
    ) AS exposure_rank
  FROM windows w
  INNER JOIN paid_recurring_exposures pe
    ON pe.paid_at < w.end_at
   AND pe.period_start <= w.end_at
   AND pe.period_end > w.end_at
  WHERE pe.subscription_created < w.end_at
    AND (
      pe.ended_at IS NULL
      OR pe.ended_at > w.end_at
    )
),

-- LEFT JOIN is intentional. A current non-core recurring price remains an end
-- exposure with tier_name NULL and is treated as an exit from the core tier.
end_plan AS (
  SELECT
    er.window_key,
    er.subscription_id,
    er.customer_id,
    er.price_id,
    pm.tier_name
  FROM end_ranked er
  LEFT JOIN price_map pm
    ON pm.price_id = er.price_id
  WHERE er.exposure_rank = 1
),

-- Includes a replacement subscription or a migration to any other core tier.
end_core_customers AS (
  SELECT DISTINCT
    window_key,
    customer_id
  FROM end_plan
  WHERE tier_name IS NOT NULL
),

classified AS (
  SELECT
    sb.window_key,
    sb.window_days,
    sb.start_at,
    sb.end_at,
    sb.subscription_id,
    sb.customer_id,
    sb.tier_name,
    sb.tier_order,

    CASE
      WHEN sb.ended_at >= sb.start_at
       AND sb.ended_at < sb.end_at
      THEN 1 ELSE 0
    END AS gross_subscription_end_flag,

    CASE
      WHEN ep.subscription_id IS NULL
        OR ep.tier_name IS NULL
        OR ep.tier_name <> sb.tier_name
      THEN 1 ELSE 0
    END AS tier_exit_flag,

    CASE
      WHEN ecc.customer_id IS NULL
      THEN 1 ELSE 0
    END AS monthly_core_service_loss_flag,

    CASE
      WHEN sb.ended_at >= sb.start_at
       AND sb.ended_at < sb.end_at
       AND ecc.customer_id IS NULL
      THEN 1 ELSE 0
    END AS event_monthly_core_logo_loss_flag
  FROM start_base sb
  LEFT JOIN end_plan ep
    ON ep.window_key = sb.window_key
   AND ep.subscription_id = sb.subscription_id
  LEFT JOIN end_core_customers ecc
    ON ecc.window_key = sb.window_key
   AND ecc.customer_id = sb.customer_id
),

tier_counts AS (
  SELECT
    w.window_key,
    w.window_days,
    w.start_at,
    w.end_at,
    pm.tier_name,
    pm.tier_order,

    COUNT(c.subscription_id)
      AS paid_subscriptions_at_start,

    COUNT(
      CASE WHEN c.gross_subscription_end_flag = 1 THEN 1 END
    ) AS gross_subscription_ends,

    COUNT(
      CASE WHEN c.tier_exit_flag = 1 THEN 1 END
    ) AS tier_exits,

    COUNT(DISTINCT c.customer_id)
      AS paying_logos_at_start,

    COUNT(
      DISTINCT CASE
        WHEN c.event_monthly_core_logo_loss_flag = 1 THEN c.customer_id
      END
    ) AS event_monthly_core_logos_lost,

    COUNT(
      DISTINCT CASE
        WHEN c.monthly_core_service_loss_flag = 1 THEN c.customer_id
      END
    ) AS monthly_core_service_logos_lost
  FROM windows w
  CROSS JOIN price_map pm
  LEFT JOIN classified c
    ON c.window_key = w.window_key
   AND c.tier_name = pm.tier_name
  GROUP BY
    w.window_key,
    w.window_days,
    w.start_at,
    w.end_at,
    pm.tier_name,
    pm.tier_order
),

total_counts AS (
  SELECT
    w.window_key,
    w.window_days,
    w.start_at,
    w.end_at,
    'All 4 tiers' AS tier_name,
    99 AS tier_order,

    COUNT(c.subscription_id)
      AS paid_subscriptions_at_start,

    COUNT(
      CASE WHEN c.gross_subscription_end_flag = 1 THEN 1 END
    ) AS gross_subscription_ends,

    COUNT(
      CASE WHEN c.tier_exit_flag = 1 THEN 1 END
    ) AS tier_exits,

    COUNT(DISTINCT c.customer_id)
      AS paying_logos_at_start,

    COUNT(
      DISTINCT CASE
        WHEN c.event_monthly_core_logo_loss_flag = 1 THEN c.customer_id
      END
    ) AS event_monthly_core_logos_lost,

    COUNT(
      DISTINCT CASE
        WHEN c.monthly_core_service_loss_flag = 1 THEN c.customer_id
      END
    ) AS monthly_core_service_logos_lost
  FROM windows w
  LEFT JOIN classified c
    ON c.window_key = w.window_key
  GROUP BY
    w.window_key,
    w.window_days,
    w.start_at,
    w.end_at
),

report_rows AS (
  SELECT * FROM tier_counts
  UNION ALL
  SELECT * FROM total_counts
)

SELECT
  window_key AS "Window",
  start_at AS "Start UTC",
  end_at AS "End UTC",
  tier_name AS "Start Tier",

  paid_subscriptions_at_start
    AS "Paid Subscriptions At Start",

  gross_subscription_ends
    AS "Gross Subscription Ends",

  ROUND(
    100.0 * CAST(gross_subscription_ends AS DOUBLE)
    / NULLIF(CAST(paid_subscriptions_at_start AS DOUBLE), 0.0),
    3
  ) AS "Gross Subscription Churn %",

  tier_exits
    AS "Original Tier Exits",

  ROUND(
    100.0 * CAST(tier_exits AS DOUBLE)
    / NULLIF(CAST(paid_subscriptions_at_start AS DOUBLE), 0.0),
    3
  ) AS "Tier Exit %",

  paying_logos_at_start
    AS "Paying Logos At Start",

  event_monthly_core_logos_lost
    AS "Ended And Not On Canonical Monthly Tier Logos",

  ROUND(
    100.0 * CAST(event_monthly_core_logos_lost AS DOUBLE)
    / NULLIF(CAST(paying_logos_at_start AS DOUBLE), 0.0),
    3
  ) AS "Event-Based Monthly-Core Logo Loss %",

  monthly_core_service_logos_lost
    AS "No Canonical Monthly Service At End Logos",

  ROUND(
    100.0 * CAST(monthly_core_service_logos_lost AS DOUBLE)
    / NULLIF(CAST(paying_logos_at_start AS DOUBLE), 0.0),
    3
  ) AS "Point-In-Time Monthly-Core Service Loss %"

FROM report_rows
ORDER BY
  window_days,
  tier_order;


-- ============================================================================
-- QUERY B: REPRODUCE CLAUDE'S ENDED-SHARE DEFINITION
-- ============================================================================
-- Reproduces:
--
--                   paid canceled subscriptions
--   ------------------------------------------------------------------
--   active + past_due subscriptions + paid canceled subscriptions
--
-- This intentionally uses a final/current subscription-item tier and accepts
-- any positive paid invoice anywhere in the subscription history. It is for
-- reconciliation only; it is not the recommended business churn definition.
--
-- Snapshot caveat: Claude's status denominator was live at the report pull.
-- Sigma reruns later will drift because subscriptions.status is not historical.

WITH
windows (
  window_key,
  window_days,
  start_at,
  end_at
) AS (
  VALUES
    (
      '30d', 30,
      TIMESTAMP '2026-08-01 11:47:21',
      TIMESTAMP '2026-08-31 11:47:21'
    ),
    (
      '120d', 120,
      TIMESTAMP '2026-05-03 11:47:21',
      TIMESTAMP '2026-08-31 11:47:21'
    )
),

price_map (
  price_id,
  tier_name,
  tier_order
) AS (
  VALUES
    ('price_1TEsavLnfBBzdwXDdu5OJYuB', 'Starter ($29/month)', 1),
    ('price_1TEseyLnfBBzdwXDH1RcdZ4e', 'Pro ($49/month)',     2),
    ('price_1TEshlLnfBBzdwXDvx4og8u2', 'Team ($79/month)',   3),
    ('price_1TEsn9LnfBBzdwXDFSJEiV43', 'Agency ($129/month)', 4)
),

final_core_plan AS (
  SELECT DISTINCT
    s.id AS subscription_id,
    s.customer_id,
    s.status,
    s.ended_at,
    s.trial_end,
    pm.tier_name,
    pm.tier_order
  FROM subscriptions s
  INNER JOIN subscription_items si
    ON si.subscription_id = s.id
  INNER JOIN price_map pm
    ON pm.price_id = si.price_id
),

ever_paid_before_snapshot AS (
  SELECT DISTINCT
    i.subscription_id
  FROM invoices i
  WHERE i.subscription_id IS NOT NULL
    AND i.status = 'paid'
    AND COALESCE(i.amount_paid, 0) > 0
    AND COALESCE(i.status_transitions_paid_at, i.date)
          < TIMESTAMP '2026-08-31 11:47:21'
),

paying_now AS (
  SELECT
    tier_name,
    tier_order,
    COUNT(DISTINCT subscription_id) AS paying_subscriptions_now
  FROM final_core_plan
  WHERE status IN ('active', 'past_due')
  GROUP BY tier_name, tier_order
),

paid_cancels AS (
  SELECT DISTINCT
    w.window_key,
    w.window_days,
    fp.tier_name,
    fp.tier_order,
    fp.subscription_id
  FROM windows w
  INNER JOIN final_core_plan fp
    ON fp.ended_at >= w.start_at
   AND fp.ended_at < w.end_at
  INNER JOIN ever_paid_before_snapshot ep
    ON ep.subscription_id = fp.subscription_id
  WHERE fp.status = 'canceled'
    AND NOT (
      fp.trial_end IS NOT NULL
      AND fp.ended_at <= fp.trial_end + INTERVAL '1' HOUR
    )
),

tier_counts AS (
  SELECT
    w.window_key,
    w.window_days,
    pm.tier_name,
    pm.tier_order,
    COALESCE(pn.paying_subscriptions_now, 0)
      AS paying_subscriptions_now,
    COUNT(DISTINCT pc.subscription_id)
      AS paid_subscriptions_ended
  FROM windows w
  CROSS JOIN price_map pm
  LEFT JOIN paying_now pn
    ON pn.tier_name = pm.tier_name
  LEFT JOIN paid_cancels pc
    ON pc.window_key = w.window_key
   AND pc.tier_name = pm.tier_name
  GROUP BY
    w.window_key,
    w.window_days,
    pm.tier_name,
    pm.tier_order,
    pn.paying_subscriptions_now
),

report_rows AS (
  SELECT * FROM tier_counts

  UNION ALL

  SELECT
    window_key,
    window_days,
    'All 4 tiers' AS tier_name,
    99 AS tier_order,
    SUM(paying_subscriptions_now) AS paying_subscriptions_now,
    SUM(paid_subscriptions_ended) AS paid_subscriptions_ended
  FROM tier_counts
  GROUP BY window_key, window_days
)

SELECT
  window_key AS "Window",
  tier_name AS "Tier",
  paying_subscriptions_now AS "Paying Subs Now",
  paid_subscriptions_ended AS "Paid Subs Ended",
  paying_subscriptions_now + paid_subscriptions_ended
    AS "Claude Denominator",
  ROUND(
    100.0 * CAST(paid_subscriptions_ended AS DOUBLE)
    / NULLIF(
        CAST(
          paying_subscriptions_now + paid_subscriptions_ended
          AS DOUBLE
        ),
        0.0
      ),
    1
  ) AS "Claude Ended Share %"
FROM report_rows
ORDER BY
  window_days,
  tier_order;

-- Snapshot acceptance checks for Query B:
--   30d total:  4,414 live + 1,162 ended -> 20.8%
--   120d total: 4,414 live + 3,828 ended -> 46.4%
--   30d ended:  Starter 720, Pro 225, Team 197, Agency 20
--   120d ended: Starter 2,429, Pro 862, Team 486, Agency 51

-- ============================================================================
-- QUERY C: CUMULATIVE SINCE-LAUNCH DISPOSITION
-- ============================================================================
-- This is intentionally separate from Query A.
--
-- It assigns each subscription to its first successfully paid canonical
-- monthly tier after launch. It also assigns each Stripe customer ID to an
-- exclusive first-paid entry tier for deduplicated logo reporting.
--
-- The result is a cumulative, varying-exposure cohort. It is NOT a monthly
-- churn rate and must not be annualized.
--
-- Price objects were created on March 25. First successful paid service began:
--   Starter: 2026-03-25 16:19:56 UTC
--   Agency:  2026-03-25 19:32:25 UTC
--   Pro:     2026-03-26 10:59:03 UTC
--   Team:    2026-03-26 15:51:41 UTC

WITH
params (
  report_end
) AS (
  VALUES (TIMESTAMP '2026-08-31 11:47:21')
),

price_map (
  price_id,
  tier_name,
  tier_order,
  price_created_at
) AS (
  VALUES
    (
      'price_1TEsavLnfBBzdwXDdu5OJYuB',
      'Starter ($29/month)',
      1,
      TIMESTAMP '2026-03-25 14:39:41'
    ),
    (
      'price_1TEseyLnfBBzdwXDH1RcdZ4e',
      'Pro ($49/month)',
      2,
      TIMESTAMP '2026-03-25 14:43:52'
    ),
    (
      'price_1TEshlLnfBBzdwXDvx4og8u2',
      'Team ($79/month)',
      3,
      TIMESTAMP '2026-03-25 14:46:45'
    ),
    (
      'price_1TEsn9LnfBBzdwXDFSJEiV43',
      'Agency ($129/month)',
      4,
      TIMESTAMP '2026-03-25 14:52:19'
    )
),

-- Keep this catalog versioned. It contains recognized canonical monthly,
-- alternate, annual, and historical PLAN products. Do not add unrelated
-- recurring add-ons.
tier_products (
  product_id
) AS (
  VALUES
    ('prod_UDJDtFxubsIPoy'),
    ('prod_UDJHllai95Kctx'),
    ('prod_UDJK8joVZdKA2v'),
    ('prod_UDJPq8QO3CSEqw'),
    ('prod_V1TMh6R6BurXyK'),
    ('prod_V1TMwh6fY22bRz'),
    ('prod_V18RAT8yxl306P'),
    ('prod_UDJEb3IVCo8YwS'),
    ('prod_UDJI7cHycrzzXv'),
    ('prod_UDJOwzRHZDvbSj'),
    ('prod_UDJR22dmPhY9xz'),
    ('prod_Q7Joa1kkMcB1gk'),
    ('prod_Q7JqaK1458BEIf'),
    ('prod_SthqEojqp9ZxwW'),
    ('prod_StiB20a4BX7lCn'),
    ('prod_StiRvbIyc1ILw4'),
    ('prod_TY1QdobsRqfrnY'),
    ('prod_Tc6fMOFljdu4tu'),
    ('prod_Tc6vzeJE3vmtLQ'),
    ('prod_RQDh61VAmeLbS6'),
    ('prod_RGVC1NUzm3BnPY'),
    ('prod_RGVE3jAEvadqbw'),
    ('prod_RGVI00SezdDn0z'),
    ('prod_Qi1iL0E4TC4PFO'),
    ('prod_RGVKY6YQxMcVro'),
    ('prod_Qi1l4RkKllNNnS'),
    ('prod_TRkdcRzTLMane8'),
    ('prod_StiGimjMKy4dHh'),
    ('prod_Sti47zaxNhfOC9'),
    ('prod_TY1XCKtE7vhSsq'),
    ('prod_Tc70WdTtS5LKRb'),
    ('prod_StiVEPEDQ0Cijr'),
    ('prod_SUU91xIS11CA5S')
),

paid_recurring_exposures AS (
  SELECT
    i.subscription_id,
    s.customer_id,
    ili.id AS invoice_line_id,
    i.id AS invoice_id,
    ili.plan_id AS price_id,
    pr.product_id,
    COALESCE(i.status_transitions_paid_at, i.date) AS paid_at,
    ili.period_start,
    ili.period_end,
    s.created AS subscription_created,
    s.ended_at
  FROM invoices i
  INNER JOIN invoice_line_items ili
    ON ili.invoice_id = i.id
  INNER JOIN prices pr
    ON pr.id = ili.plan_id
  INNER JOIN tier_products tp
    ON tp.product_id = pr.product_id
  INNER JOIN subscriptions s
    ON s.id = i.subscription_id
  WHERE i.subscription_id IS NOT NULL
    AND i.status = 'paid'
    AND COALESCE(i.amount_paid, 0) > 0
    AND ili.type = 'subscription'
    AND COALESCE(ili.amount, 0) > 0
    AND ili.period_end > ili.period_start
),

launch_baseline AS (
  SELECT
    pm.price_id,
    pm.tier_name,
    pm.tier_order,
    pm.price_created_at,
    MIN(pe.period_start) AS metric_launch_at,
    MIN(pe.paid_at) AS first_successful_payment_at
  FROM price_map pm
  CROSS JOIN params p
  LEFT JOIN paid_recurring_exposures pe
    ON pe.price_id = pm.price_id
   AND pe.paid_at < p.report_end
   AND pe.period_start < p.report_end
   AND pe.paid_at >= pm.price_created_at
   AND pe.period_start >= pm.price_created_at
   AND (
     pe.ended_at IS NULL
     OR pe.paid_at <= pe.ended_at
   )
  GROUP BY
    pm.price_id,
    pm.tier_name,
    pm.tier_order,
    pm.price_created_at
),

subscription_entry_ranked AS (
  SELECT
    p.report_end,
    pe.*,
    pm.tier_name,
    pm.tier_order,
    ROW_NUMBER() OVER (
      PARTITION BY pe.subscription_id
      ORDER BY
        pe.period_start ASC,
        pe.paid_at ASC,
        pe.period_end ASC,
        pm.tier_order ASC,
        pe.invoice_id ASC,
        pe.invoice_line_id ASC
    ) AS entry_rank
  FROM params p
  INNER JOIN paid_recurring_exposures pe
    ON pe.paid_at < p.report_end
   AND pe.period_start < p.report_end
  INNER JOIN price_map pm
    ON pm.price_id = pe.price_id
   AND pe.paid_at >= pm.price_created_at
   AND pe.period_start >= pm.price_created_at
  WHERE pe.subscription_created < p.report_end
    -- Prevent a payment arriving only after termination from retroactively
    -- making a subscription "paid before it was lost."
    AND (
      pe.ended_at IS NULL
      OR pe.paid_at <= pe.ended_at
    )
),

subscription_entry_base AS (
  SELECT
    report_end,
    subscription_id,
    customer_id,
    ended_at,
    tier_name,
    tier_order,
    period_start AS entry_at,
    period_end AS entry_period_end,
    paid_at AS entry_paid_at
  FROM subscription_entry_ranked
  WHERE entry_rank = 1
),

customer_entry_ranked AS (
  SELECT
    seb.*,
    ROW_NUMBER() OVER (
      PARTITION BY seb.customer_id
      ORDER BY
        seb.entry_at ASC,
        seb.entry_paid_at ASC,
        seb.entry_period_end ASC,
        seb.tier_order ASC,
        seb.subscription_id ASC
    ) AS customer_entry_rank
  FROM subscription_entry_base seb
),

customer_entry_base AS (
  SELECT *
  FROM customer_entry_ranked
  WHERE customer_entry_rank = 1
),

end_ranked AS (
  SELECT
    p.report_end,
    pe.*,
    ROW_NUMBER() OVER (
      PARTITION BY pe.subscription_id
      ORDER BY
        pe.paid_at DESC,
        pe.period_start DESC,
        pe.period_end DESC,
        pe.invoice_id DESC,
        pe.invoice_line_id DESC
    ) AS exposure_rank
  FROM params p
  INNER JOIN paid_recurring_exposures pe
    ON pe.paid_at < p.report_end
   AND pe.period_start <= p.report_end
   AND pe.period_end > p.report_end
  WHERE pe.subscription_created < p.report_end
    AND (
      pe.ended_at IS NULL
      OR pe.ended_at > p.report_end
    )
),

-- A recognized noncanonical plan can win the end rank. The LEFT JOIN makes it
-- a canonical-monthly portfolio exit instead of allowing an older core line
-- to hide the migration.
end_plan AS (
  SELECT
    er.subscription_id,
    er.customer_id,
    pm.tier_name
  FROM end_ranked er
  LEFT JOIN price_map pm
    ON pm.price_id = er.price_id
  WHERE er.exposure_rank = 1
),

end_core_customers AS (
  SELECT DISTINCT
    customer_id
  FROM end_plan
  WHERE tier_name IS NOT NULL
),

subscription_classified AS (
  SELECT
    seb.*,
    CASE
      WHEN seb.ended_at >= seb.entry_at
       AND seb.ended_at < seb.report_end
      THEN 1 ELSE 0
    END AS terminal_end_flag,
    CASE
      WHEN ep.subscription_id IS NULL
        OR ep.tier_name IS NULL
        OR ep.tier_name <> seb.tier_name
      THEN 1 ELSE 0
    END AS original_tier_exit_flag
  FROM subscription_entry_base seb
  LEFT JOIN end_plan ep
    ON ep.subscription_id = seb.subscription_id
),

customer_classified AS (
  SELECT
    ceb.*,
    CASE
      WHEN ecc.customer_id IS NULL
      THEN 1 ELSE 0
    END AS monthly_core_service_loss_flag
  FROM customer_entry_base ceb
  LEFT JOIN end_core_customers ecc
    ON ecc.customer_id = ceb.customer_id
),

tier_subscription_counts AS (
  SELECT
    pm.tier_name,
    pm.tier_order,
    COUNT(sc.subscription_id)
      AS ever_paid_subscriptions_since_launch,
    COUNT(
      CASE WHEN sc.terminal_end_flag = 1 THEN 1 END
    ) AS terminal_subscription_ends,
    COUNT(
      CASE WHEN sc.original_tier_exit_flag = 1 THEN 1 END
    ) AS original_tier_exits_at_cutoff
  FROM price_map pm
  LEFT JOIN subscription_classified sc
    ON sc.tier_name = pm.tier_name
  GROUP BY
    pm.tier_name,
    pm.tier_order
),

tier_customer_counts AS (
  SELECT
    pm.tier_name,
    pm.tier_order,
    COUNT(cc.customer_id)
      AS ever_paid_logos_since_launch,
    COUNT(
      CASE WHEN cc.monthly_core_service_loss_flag = 0 THEN 1 END
    ) AS retained_on_canonical_monthly_logos,
    COUNT(
      CASE WHEN cc.monthly_core_service_loss_flag = 1 THEN 1 END
    ) AS no_canonical_monthly_service_at_cutoff_logos
  FROM price_map pm
  LEFT JOIN customer_classified cc
    ON cc.tier_name = pm.tier_name
  GROUP BY
    pm.tier_name,
    pm.tier_order
),

tier_rows AS (
  SELECT
    'Since launch' AS window_key,
    pm.tier_name,
    pm.tier_order,
    lb.price_created_at,
    lb.metric_launch_at,
    lb.first_successful_payment_at,
    tsc.ever_paid_subscriptions_since_launch,
    tsc.terminal_subscription_ends,
    tsc.original_tier_exits_at_cutoff,
    tcc.ever_paid_logos_since_launch,
    tcc.retained_on_canonical_monthly_logos,
    tcc.no_canonical_monthly_service_at_cutoff_logos
  FROM price_map pm
  INNER JOIN launch_baseline lb
    ON lb.price_id = pm.price_id
  INNER JOIN tier_subscription_counts tsc
    ON tsc.tier_name = pm.tier_name
  INNER JOIN tier_customer_counts tcc
    ON tcc.tier_name = pm.tier_name
),

-- Aggregate subscription and customer totals independently so the deduplicated
-- total cannot create a many-to-many cross product.
total_subscription_counts AS (
  SELECT
    COUNT(subscription_id)
      AS ever_paid_subscriptions_since_launch,
    COUNT(
      CASE WHEN terminal_end_flag = 1 THEN 1 END
    ) AS terminal_subscription_ends,
    COUNT(
      CASE WHEN original_tier_exit_flag = 1 THEN 1 END
    ) AS original_tier_exits_at_cutoff
  FROM subscription_classified
),

total_customer_counts AS (
  SELECT
    COUNT(customer_id)
      AS ever_paid_logos_since_launch,
    COUNT(
      CASE WHEN monthly_core_service_loss_flag = 0 THEN 1 END
    ) AS retained_on_canonical_monthly_logos,
    COUNT(
      CASE WHEN monthly_core_service_loss_flag = 1 THEN 1 END
    ) AS no_canonical_monthly_service_at_cutoff_logos
  FROM customer_classified
),

safe_total_row AS (
  SELECT
    'Since launch' AS window_key,
    'All 4 tiers' AS tier_name,
    99 AS tier_order,
    MIN(lb.price_created_at) AS price_created_at,
    MIN(lb.metric_launch_at) AS metric_launch_at,
    MIN(lb.first_successful_payment_at) AS first_successful_payment_at,
    tsc.ever_paid_subscriptions_since_launch,
    tsc.terminal_subscription_ends,
    tsc.original_tier_exits_at_cutoff,
    tcc.ever_paid_logos_since_launch,
    tcc.retained_on_canonical_monthly_logos,
    tcc.no_canonical_monthly_service_at_cutoff_logos
  FROM launch_baseline lb
  CROSS JOIN total_subscription_counts tsc
  CROSS JOIN total_customer_counts tcc
  GROUP BY
    tsc.ever_paid_subscriptions_since_launch,
    tsc.terminal_subscription_ends,
    tsc.original_tier_exits_at_cutoff,
    tcc.ever_paid_logos_since_launch,
    tcc.retained_on_canonical_monthly_logos,
    tcc.no_canonical_monthly_service_at_cutoff_logos
),

report_rows AS (
  SELECT * FROM tier_rows
  UNION ALL
  SELECT * FROM safe_total_row
)

SELECT
  window_key AS "Window",
  tier_name AS "Entry Tier",
  price_created_at AS "Price Created UTC",
  metric_launch_at AS "First Paid Service UTC",
  first_successful_payment_at AS "First Successful Payment UTC",

  ever_paid_subscriptions_since_launch
    AS "Ever-Paid Subscriptions Since Launch",

  terminal_subscription_ends
    AS "Terminal Subscription Ends",

  ROUND(
    100.0 * CAST(terminal_subscription_ends AS DOUBLE)
    / NULLIF(
        CAST(ever_paid_subscriptions_since_launch AS DOUBLE),
        0.0
      ),
    3
  ) AS "Cumulative Gross Subscription Attrition %",

  original_tier_exits_at_cutoff
    AS "Original Tier Exits At Cutoff",

  ever_paid_logos_since_launch
    AS "Ever-Paid Logos Since Launch",

  retained_on_canonical_monthly_logos
    AS "Retained On Canonical Monthly At Cutoff Logos",

  no_canonical_monthly_service_at_cutoff_logos
    AS "No Canonical Monthly Service At Cutoff Logos",

  ROUND(
    100.0 * CAST(
      no_canonical_monthly_service_at_cutoff_logos
      AS DOUBLE
    )
    / NULLIF(
        CAST(ever_paid_logos_since_launch AS DOUBLE),
        0.0
      ),
    3
  ) AS "Cumulative Monthly-Core Service Loss %"

FROM report_rows
ORDER BY tier_order;

-- Query C acceptance checks at the frozen cutoff:
--   Starter: 5,117 entrant subs / 2,512 terminal ends / 49.091%;
--            4,834 entrant customer IDs / 2,456 retained / 2,378 not
--            retained / 49.193% monthly-core service loss.
--   Pro:     1,699 / 929 / 54.679%; 1,665 / 763 / 902 / 54.174%.
--   Team:    1,234 / 448 / 36.305%; 1,195 / 750 / 445 / 37.238%.
--   Agency:  113 / 39 / 34.513%; 111 / 74 / 37 / 33.333%.
--   Total:   8,163 / 3,928 / 48.120%; 7,805 / 4,043 / 3,762 / 48.200%.


-- ============================================================================
-- QUERY D: FROZEN CLAUDE-VS-AUDITED RECONCILIATION
-- ============================================================================
-- Query B's live status denominator will drift on rerun. These VALUES preserve
-- the exact HTML snapshot and join it conceptually to Query A's frozen
-- acceptance cells. The definitions differ; percentage deltas are diagnostic.

WITH
comparison (
  window_key,
  tier_name,
  claude_end_status_base,
  claude_paid_end_events,
  claude_ended_share_pct,
  audited_cohort_denominator,
  audited_gross_ends,
  audited_gross_churn_pct
) AS (
  VALUES
    ('30d','Starter ($29/month)',2566,720,21.911,2242,620,27.654),
    ('30d','Pro ($49/month)',702,225,24.272,733,209,28.513),
    ('30d','Team ($79/month)',985,197,16.667,660,150,22.727),
    ('30d','Agency ($129/month)',161,20,11.050,31,3,9.677),
    ('30d','All 4 tiers',4414,1162,20.839,3666,982,26.787),
    ('120d','Starter ($29/month)',2566,2429,48.629,978,685,70.041),
    ('120d','Pro ($49/month)',702,862,55.115,388,258,66.495),
    ('120d','Team ($79/month)',985,486,33.039,121,59,48.760),
    ('120d','Agency ($129/month)',161,51,24.057,19,12,63.158),
    ('120d','All 4 tiers',4414,3828,46.445,1506,1014,67.331),
    ('since_launch','Starter ($29/month)',2566,2510,49.448,5117,2512,49.091),
    ('since_launch','Pro ($49/month)',702,907,56.370,1699,929,54.679),
    ('since_launch','Team ($79/month)',985,497,33.536,1234,448,36.305),
    ('since_launch','Agency ($129/month)',161,57,26.147,113,39,34.513),
    ('since_launch','All 4 tiers',4414,3971,47.358,8163,3928,48.120)
)

SELECT
  window_key AS "Window",
  tier_name AS "Tier",
  claude_end_status_base AS "Claude End Status Base",
  claude_paid_end_events AS "Claude Paid End Events",
  claude_ended_share_pct AS "Claude Ended Share %",
  audited_cohort_denominator AS "Audited Cohort Denominator",
  audited_gross_ends AS "Audited Gross Ends",
  audited_gross_churn_pct AS "Audited Gross Churn %",
  ROUND(
    audited_gross_churn_pct - claude_ended_share_pct,
    3
  ) AS "Percentage-Point Difference",
  CASE
    WHEN window_key = 'since_launch'
    THEN 'Epoch-zero end-survivor share vs Mar-25/26 cumulative paid-entry cohort; definitions differ'
    ELSE 'End-survivor ended-share vs fixed paid start cohort; definitions differ'
  END AS "Comparison Note"
FROM comparison
ORDER BY
  CASE window_key
    WHEN '30d' THEN 30
    WHEN '120d' THEN 120
    ELSE 999
  END,
  CASE tier_name
    WHEN 'Starter ($29/month)' THEN 1
    WHEN 'Pro ($49/month)' THEN 2
    WHEN 'Team ($79/month)' THEN 3
    WHEN 'Agency ($129/month)' THEN 4
    ELSE 99
  END;

-- Query C/D limitations to disclose:
--   1. This is canonical-monthly portfolio loss, not whole-business logo churn.
--   2. Positive invoices are not net of later refunds or disputes.
--   3. Version the 33-product migration-detection catalog.
--   4. Cumulative launch attrition is not a monthly rate.
--   5. Record Sigma data_load_time with every export.
--   6. If invoice_line_items exposes price_id instead of plan_id, replace the
--      relevant ili.plan_id references. subscription_items.price_id remains.
--   7. Never put add-on products in tier_products.
