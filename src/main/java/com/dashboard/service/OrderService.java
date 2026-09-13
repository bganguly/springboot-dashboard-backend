package com.dashboard.service;

import com.dashboard.dto.*;
import com.dashboard.entity.*;
import com.dashboard.repository.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.stream.Collectors;

@Service
@RequiredArgsConstructor
public class OrderService {

    private static final int DEFAULT_PAGE_SIZE = 20;
    private static final int MAX_PAGE_SIZE = 100;
    private static final DateTimeFormatter ISO = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'");
    private static final int COUNT_CAP = 10_000;
    // Returned by exactCount when the result exceeds COUNT_CAP and the exact
    // total wasn't computed. Callers check rawTotal == COUNT_SENTINEL to set
    // approximate=true. Must not equal a plausible real order count near the cap.
    private static final long COUNT_SENTINEL = (long) COUNT_CAP + 1;

    private final NamedParameterJdbcTemplate jdbc;
    private final OrderRepository orderRepository;
    private final CustomerRepository customerRepository;
    private final RegionRepository regionRepository;
    private final ProductRepository productRepository;
    private final AggregatesCache aggregatesCache;
    private final TypesenseService typesenseService;

    public OrderListResult listOrders(
            String q, int page, int pageSize, String sort, String dir,
            String status, String regionCode,
            String from, String to,
            BigDecimal minTotal, BigDecimal maxTotal) {

        pageSize = Math.min(Math.max(pageSize, 1), MAX_PAGE_SIZE);
        page = Math.max(page, 1);

        String safeSort = Set.of("placedAt", "total", "status", "customer", "id").contains(sort) ? sort : "placedAt";
        String safeDir = "asc".equalsIgnoreCase(dir) ? "ASC" : "DESC";

        if (typesenseService.isEnabled() && q != null && !q.isBlank()) {
            TypesenseService.SearchResult ts = typesenseService.search(q, page, pageSize);
            if (ts != null) {
                return listOrdersFromTypesense(ts, page, pageSize, safeSort, safeDir,
                        status, regionCode, from, to, minTotal, maxTotal);
            }
            // Typesense failed — fall through to Postgres
        }

        var params = new MapSqlParameterSource();
        String ctePrefix = buildSearchCte(q, params);
        var where = buildWhere(q, status, regionCode, from, to, minTotal, maxTotal, params);

        long rawTotal = exactCount(q, status, regionCode, from, to, minTotal, maxTotal);
        boolean approximate = rawTotal == COUNT_SENTINEL;
        long total = approximate ? COUNT_CAP : rawTotal;
        int totalPages = (int) Math.ceil((double) total / pageSize);

        String orderBy = switch (safeSort) {
            case "customer" -> "c.\"firstName\" " + safeDir + ", c.\"lastName\" " + safeDir + ", o.\"placedAt\" DESC";
            case "total"    -> "o.total " + safeDir + ", o.\"placedAt\" DESC";
            case "status"   -> "o.status " + safeDir + ", o.\"placedAt\" DESC";
            case "id"       -> "o.id " + safeDir;
            default         -> "o.\"placedAt\" " + safeDir;
        };

        // The last page is exactly as expensive to reach via OFFSET as any other
        // deep page (Postgres must sort/skip everything before it regardless of
        // which end you're nominally "closer" to) — but scanning the SAME index
        // from the opposite end with a small LIMIT and no OFFSET is just as cheap
        // as page 1, so flip the sort and take the first N rows from that end
        // instead, then reverse them back into normal display order.
        boolean useReverseScan = totalPages > 1 && page == totalPages;
        int limit = pageSize;
        int offset = (page - 1) * pageSize;
        String effectiveOrderBy = orderBy;
        if (useReverseScan) {
            limit = (int) (total - (long) (totalPages - 1) * pageSize);
            offset = 0;
            effectiveOrderBy = flipOrderByDirection(orderBy);
        }

        String dataSql = ctePrefix + """
                SELECT o.id, o.status, o.total, o.currency, o.notes, o."placedAt",
                       c.id AS c_id, c.email, c."firstName", c."lastName", c.phone,
                       r.id AS r_id, r.code AS r_code, r.name AS r_name
                FROM orders o
                JOIN customers c ON c.id = o."customerId"
                JOIN regions r ON r.id = o."regionId"
                """ + where +
                " ORDER BY " + effectiveOrderBy +
                " LIMIT :limit OFFSET :offset";
        params.addValue("limit", limit).addValue("offset", offset);

        List<Map<String, Object>> rows = jdbc.queryForList(dataSql, params);
        if (useReverseScan) rows = new ArrayList<>(rows).reversed();

        return toResult(rows, page, pageSize, total, totalPages, approximate);
    }

    /**
     * Cursor (keyset) fetch of the page immediately before/after the given
     * anchor row, for the default placedAt/desc sort only — the one column
     * with a dedicated index, and the app's actual default view. An OFFSET
     * query's cost scales with how deep the requested page is; a keyset query
     * seeks directly to the cursor via the index and reads forward/backward,
     * so it's equally cheap at any depth. total/totalPages are recomputed via
     * the same cached-count path (typically a cache hit, since the filter
     * signature is unchanged from the page that produced this cursor) purely
     * so the response shape matches listOrders' — the caller (which already
     * knows the target page number locally) supplies `page` for display.
     */
    public OrderListResult listOrdersByCursor(
            String q, int page, int pageSize,
            String status, String regionCode,
            String from, String to,
            BigDecimal minTotal, BigDecimal maxTotal,
            int cursorId, String cursorPlacedAt, boolean forward) {

        pageSize = Math.min(Math.max(pageSize, 1), MAX_PAGE_SIZE);

        var params = new MapSqlParameterSource();
        var where = buildWhere(q, status, regionCode, from, to, minTotal, maxTotal, params);

        boolean needsRegionJoin = regionCode != null && !regionCode.isBlank();
        String regionJoin = needsRegionJoin ? "JOIN regions r ON r.id = o.\"regionId\" " : "";
        long rawTotal = exactCount(q, status, regionCode, from, to, minTotal, maxTotal);
        boolean approximate = rawTotal == COUNT_SENTINEL;
        long total = approximate ? COUNT_CAP : rawTotal;
        int totalPages = (int) Math.ceil((double) total / pageSize);

        String cursorClause = forward
                ? "(o.\"placedAt\", o.id) < (:cursorPlacedAt::timestamptz, :cursorId)"
                : "(o.\"placedAt\", o.id) > (:cursorPlacedAt::timestamptz, :cursorId)";
        params.addValue("cursorPlacedAt", cursorPlacedAt).addValue("cursorId", cursorId);
        String combinedWhere = where.isEmpty() ? "WHERE " + cursorClause : where + " AND " + cursorClause;
        String orderBy = forward ? "o.\"placedAt\" DESC, o.id DESC" : "o.\"placedAt\" ASC, o.id ASC";

        String dataSql = """
                SELECT o.id, o.status, o.total, o.currency, o.notes, o."placedAt",
                       c.id AS c_id, c.email, c."firstName", c."lastName", c.phone,
                       r.id AS r_id, r.code AS r_code, r.name AS r_name
                FROM orders o
                JOIN customers c ON c.id = o."customerId"
                JOIN regions r ON r.id = o."regionId"
                """ + combinedWhere +
                " ORDER BY " + orderBy +
                " LIMIT :limit";
        params.addValue("limit", pageSize);

        List<Map<String, Object>> rows = jdbc.queryForList(dataSql, params);
        // A backward (prev) fetch reads oldest-first so it can seek off the
        // cursor with a plain LIMIT — flip back to the newest-first order the
        // UI expects everywhere else.
        if (!forward) rows = new ArrayList<>(rows).reversed();

        return toResult(rows, page, pageSize, total, totalPages, approximate);
    }

    private OrderListResult toResult(List<Map<String, Object>> rows, int page, int pageSize,
                                      long total, int totalPages, boolean approximate) {
        if (rows.isEmpty()) {
            return new OrderListResult(List.of(), page, pageSize, total, totalPages, approximate);
        }

        List<Integer> orderIds = rows.stream()
                .map(r -> ((Number) r.get("id")).intValue())
                .toList();

        Map<Integer, List<OrderItemDTO>> itemsByOrder = fetchItems(orderIds);

        List<OrderDTO> data = rows.stream().map(r -> {
            int id = ((Number) r.get("id")).intValue();
            return new OrderDTO(
                    id,
                    (String) r.get("status"),
                    (BigDecimal) r.get("total"),
                    (String) r.get("currency"),
                    (String) r.get("notes"),
                    formatTs(r.get("placedAt")),
                    new CustomerSummaryDTO(
                            ((Number) r.get("c_id")).intValue(),
                            (String) r.get("email"),
                            (String) r.get("firstName"),
                            (String) r.get("lastName")),
                    new RegionDTO(
                            ((Number) r.get("r_id")).intValue(),
                            (String) r.get("r_code"),
                            (String) r.get("r_name")),
                    itemsByOrder.getOrDefault(id, List.of())
            );
        }).toList();

        return new OrderListResult(data, page, pageSize, total, totalPages, approximate);
    }

    private String flipOrderByDirection(String orderBy) {
        return orderBy.replace(" DESC", "  ").replace(" ASC", " DESC").replace("  ", " ASC");
    }

    /**
     * Exact distinct order count for the given filters — the same path
     * listOrders uses for its own total, so /api/aggregates's grand total
     * (see AggregateService.getExactTotal) is guaranteed to agree with the
     * orders list whenever they cover the same range/filters. Summing the
     * per-category aggregate rows instead would double-count any order whose
     * items span more than one category.
     *
     * A pure date range (no q/status/region/total filter) sums
     * daily_order_count instead — cheap regardless of range width, and never
     * dependent on count_cache being pre-warmed for that exact range (unlike
     * a raw COUNT(*), which on a cache miss blocks the caller synchronously).
     * Any other filter combination falls back to the cached exact-count path.
     */
    public static boolean isApproximateCount(long count) { return count == COUNT_SENTINEL; }
    public static long adjustCount(long count) { return count == COUNT_SENTINEL ? COUNT_CAP : count; }

    private static boolean hasShortToken(String q) {
        if (q == null || q.isBlank()) return false;
        for (String t : q.strip().split("\\s+")) {
            if (t.length() < 3) return true;
        }
        return false;
    }

    public long exactCount(String q, String status, String regionCode,
                            String from, String to,
                            BigDecimal minTotal, BigDecimal maxTotal) {
        Long rollup = tryDailyOrderCountRollup(q, status, regionCode, from, to, minTotal, maxTotal);
        if (rollup != null) return rollup;

        var params = new MapSqlParameterSource();
        var where = buildWhere(q, status, regionCode, from, to, minTotal, maxTotal, params);
        boolean needsRegionJoin = regionCode != null && !regionCode.isBlank();
        String regionJoin = needsRegionJoin ? "JOIN regions r ON r.id = o.\"regionId\" " : "";
        String cacheKey = buildCountCacheKey(q, status, regionCode, from, to, minTotal, maxTotal);

        if (hasShortToken(q)) {
            // Check cache first — a prior /count call may have written the exact value
            try {
                List<Long> hit = jdbc.queryForList(
                    "SELECT total FROM count_cache WHERE cache_key = :k AND cached_at > NOW() - INTERVAL '30 days'",
                    new MapSqlParameterSource("k", cacheKey), Long.class);
                if (!hit.isEmpty()) return hit.get(0);
            } catch (Exception ignored) {}
            // Cap the scan at COUNT_SENTINEL rows — if the subquery returns exactly
            // COUNT_SENTINEL it means there are at least that many rows (exact unknown)
            String cappedSql = "SELECT COUNT(*) FROM (SELECT 1 FROM orders o " + regionJoin + where +
                               " LIMIT " + COUNT_SENTINEL + ") _cap";
            long capped = Objects.requireNonNull(jdbc.queryForObject(cappedSql, params, Long.class));
            // Only cache exact results (capped < sentinel) — sentinel stays uncached
            // so a subsequent /count call can write the real value and heal the cache
            if (capped < COUNT_SENTINEL) {
                try {
                    jdbc.update(
                        "INSERT INTO count_cache (cache_key, total, cached_at) VALUES (:k, :t, NOW()) " +
                        "ON CONFLICT (cache_key) DO UPDATE SET total = :t, cached_at = NOW()",
                        new MapSqlParameterSource("k", cacheKey).addValue("t", capped));
                } catch (Exception ignored) {}
            }
            return capped;
        }

        String countSql = "SELECT COUNT(*) FROM orders o " + regionJoin + where;
        return cachedCount(countSql, params, cacheKey);
    }

    /** Uncapped exact count — used by GET /api/orders/count. Always writes the
     *  real total to count_cache so subsequent exactCount calls get a cache hit
     *  instead of re-running the capped subquery. */
    public long exactCountUncapped(String q, String status, String regionCode,
                                    String from, String to,
                                    BigDecimal minTotal, BigDecimal maxTotal) {
        Long rollup = tryDailyOrderCountRollup(q, status, regionCode, from, to, minTotal, maxTotal);
        if (rollup != null) return rollup;

        var params = new MapSqlParameterSource();
        var where = buildWhere(q, status, regionCode, from, to, minTotal, maxTotal, params);
        boolean needsRegionJoin = regionCode != null && !regionCode.isBlank();
        String regionJoin = needsRegionJoin ? "JOIN regions r ON r.id = o.\"regionId\" " : "";
        String countSql = "SELECT COUNT(*) FROM orders o " + regionJoin + where;
        String cacheKey = buildCountCacheKey(q, status, regionCode, from, to, minTotal, maxTotal);
        return cachedCount(countSql, params, cacheKey);
    }

    private Long tryDailyOrderCountRollup(String q, String status, String regionCode,
                                          String from, String to,
                                          BigDecimal minTotal, BigDecimal maxTotal) {
        boolean pureDateRange = (q == null || q.isBlank())
                && (status == null || status.isBlank())
                && (regionCode == null || regionCode.isBlank())
                && minTotal == null && maxTotal == null;
        if (!pureDateRange) return null;
        if (from == null || from.isBlank() || to == null || to.isBlank()) return null;

        var params = new MapSqlParameterSource().addValue("from", from).addValue("to", to);
        Long sum = jdbc.queryForObject(
                "SELECT COALESCE(SUM(\"totalOrders\"), 0) FROM daily_order_count " +
                "WHERE date BETWEEN :from::date AND :to::date", params, Long.class);
        return sum != null ? sum : 0L;
    }

    @Transactional
    public Map<String, Object> createOrder(CreateOrderRequest req) {
        Customer customer = customerRepository.findById(req.customerId())
                .orElseThrow(() -> new IllegalArgumentException("Customer not found: " + req.customerId()));
        Region region = regionRepository.findById(req.regionId())
                .orElseThrow(() -> new IllegalArgumentException("Region not found: " + req.regionId()));

        Order order = new Order();
        order.setCustomer(customer);
        order.setRegion(region);
        order.setCurrency(req.currency() != null ? req.currency() : "USD");
        order.setNotes(req.notes());
        order.setPlacedAt(LocalDateTime.now());
        order.setUpdatedAt(LocalDateTime.now());

        BigDecimal total = BigDecimal.ZERO;
        List<OrderItem> items = new ArrayList<>();
        for (var itemReq : req.items()) {
            Product product = productRepository.findById(itemReq.productId())
                    .orElseThrow(() -> new IllegalArgumentException("Product not found: " + itemReq.productId()));
            OrderItem item = new OrderItem();
            item.setOrder(order);
            item.setProduct(product);
            item.setQuantity(itemReq.quantity());
            item.setUnitPrice(itemReq.unitPrice());
            BigDecimal disc = itemReq.discount() != null ? itemReq.discount() : BigDecimal.ZERO;
            item.setDiscount(disc);
            BigDecimal lineTotal = itemReq.unitPrice()
                    .multiply(BigDecimal.valueOf(itemReq.quantity()))
                    .multiply(BigDecimal.ONE.subtract(disc));
            total = total.add(lineTotal);
            items.add(item);
        }
        order.setTotal(total);
        order.setItems(items);
        Order saved = orderRepository.save(order);

        // Same transaction as the order write, so this table is never even
        // momentarily out of sync — a date-range total can be a cheap SUM
        // over it (see AggregateService.getExactTotal) instead of a COUNT(*)
        // scan over every matching order.
        jdbc.update(
                "INSERT INTO daily_order_count (date, \"totalOrders\") VALUES (:date, 1) " +
                "ON CONFLICT (date) DO UPDATE SET \"totalOrders\" = daily_order_count.\"totalOrders\" + 1",
                new MapSqlParameterSource("date", saved.getPlacedAt().toLocalDate()));

        // count_cache has no active invalidation otherwise (just a 30-day
        // passive TTL) — a new order makes every cached exact count a
        // potential undercount until something forces a recompute. A
        // filter-less cache_key (q="") always covers every order, so it's
        // always invalidated. A q= entry is only invalidated if this new
        // order's own search_text could actually match that token — sparing
        // every unrelated search token (e.g. CountCacheWarmup's pre-warmed
        // customer-name lookups) from being wiped by every single order
        // created anywhere else in the app.
        try {
            String searchText = jdbc.queryForObject(
                    "SELECT search_text FROM orders WHERE id = :id",
                    new MapSqlParameterSource("id", saved.getId()), String.class);
            jdbc.update(
                    "DELETE FROM count_cache WHERE " +
                    "substring(cache_key from 'q=([^&]*)') = '' " +
                    "OR (:searchText IS NOT NULL AND :searchText ILIKE '%' || substring(cache_key from 'q=([^&]*)') || '%')",
                    new MapSqlParameterSource("searchText", searchText));
        } catch (Exception ignored) {}

        // Evict the in-process aggregates cache after commit so the next
        // chart request recomputes with the new order included.
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override public void afterCommit() { aggregatesCache.invalidateAll(); }
        });

        return Map.of(
                "id", saved.getId(),
                "status", saved.getStatus().name(),
                "total", saved.getTotal(),
                "placedAt", ISO.format(saved.getPlacedAt()));
    }

    // --- helpers ---

    private OrderListResult listOrdersFromTypesense(
            TypesenseService.SearchResult ts,
            int page, int pageSize, String safeSort, String safeDir,
            String status, String regionCode, String from, String to,
            BigDecimal minTotal, BigDecimal maxTotal) {

        if (ts.ids().isEmpty()) {
            return new OrderListResult(List.of(), page, pageSize, 0, 0, false);
        }
        long total = ts.total();
        int totalPages = (int) Math.ceil((double) total / pageSize);

        String orderBy = switch (safeSort) {
            case "customer" -> "c.\"firstName\" " + safeDir + ", c.\"lastName\" " + safeDir + ", o.\"placedAt\" DESC";
            case "total"    -> "o.total " + safeDir + ", o.\"placedAt\" DESC";
            case "status"   -> "o.status " + safeDir + ", o.\"placedAt\" DESC";
            case "id"       -> "o.id " + safeDir;
            default         -> "o.\"placedAt\" " + safeDir;
        };

        var params = new MapSqlParameterSource();
        // Non-text filters still applied in Postgres on the Typesense-returned IDs
        var nonTextWhere = buildWhere(null, status, regionCode, from, to, minTotal, maxTotal, params);
        params.addValue("tsIds", ts.ids().toArray(new Integer[0]));
        String where = nonTextWhere.isEmpty()
                ? "WHERE o.id = ANY(:tsIds)"
                : nonTextWhere + " AND o.id = ANY(:tsIds)";

        String dataSql = """
                SELECT o.id, o.status, o.total, o.currency, o.notes, o."placedAt",
                       c.id AS c_id, c.email, c."firstName", c."lastName", c.phone,
                       r.id AS r_id, r.code AS r_code, r.name AS r_name
                FROM orders o
                JOIN customers c ON c.id = o."customerId"
                JOIN regions r ON r.id = o."regionId"
                """ + where + " ORDER BY " + orderBy;

        List<Map<String, Object>> rows = jdbc.queryForList(dataSql, params);
        return toResult(rows, page, pageSize, total, totalPages, false);
    }

    private String buildSearchCte(String q, MapSqlParameterSource params) {
        return ""; // search_text column handles all search — no CTE needed
    }

    private String buildWhere(String q, String status, String regionCode,
                               String from, String to,
                               BigDecimal minTotal, BigDecimal maxTotal,
                               MapSqlParameterSource params) {
        List<String> clauses = new ArrayList<>();

        if (q != null && !q.isBlank()) {
            String[] tokens = q.strip().split("\\s+");
            for (int i = 0; i < tokens.length; i++) {
                String key = "q" + i;
                clauses.add("o.search_text ILIKE :" + key);
                params.addValue(key, "%" + tokens[i] + "%");
            }
        }
        if (status != null && !status.isBlank()) {
            List<String> statuses = Arrays.stream(status.split(","))
                    .map(String::strip).filter(s -> !s.isEmpty()).toList();
            clauses.add("o.status = ANY(ARRAY[" +
                    statuses.stream().map(s -> "'" + s + "'::\"OrderStatus\"").collect(Collectors.joining(",")) + "])");
        }
        if (regionCode != null && !regionCode.isBlank()) {
            List<String> codes = Arrays.stream(regionCode.split(","))
                    .map(String::strip).filter(s -> !s.isEmpty()).toList();
            clauses.add("r.code = ANY(ARRAY[" +
                    codes.stream().map(c -> "'" + c + "'").collect(Collectors.joining(",")) + "])");
        }
        if (from != null && !from.isBlank()) {
            clauses.add("o.\"placedAt\" >= :from::timestamptz");
            params.addValue("from", from);
        }
        if (to != null && !to.isBlank()) {
            clauses.add("o.\"placedAt\" <= (:to::date + interval '1 day' - interval '1 second')");
            params.addValue("to", to);
        }
        if (minTotal != null) {
            clauses.add("o.total >= :minTotal");
            params.addValue("minTotal", minTotal);
        }
        if (maxTotal != null) {
            clauses.add("o.total <= :maxTotal");
            params.addValue("maxTotal", maxTotal);
        }
        return clauses.isEmpty() ? "" : "WHERE " + String.join(" AND ", clauses);
    }

    private Map<Integer, List<OrderItemDTO>> fetchItems(List<Integer> orderIds) {
        if (orderIds.isEmpty()) return Map.of();
        String sql = """
                SELECT oi.id, oi."orderId", oi."productId", oi.quantity, oi."unitPrice", oi.discount,
                       p.sku, p.name AS p_name
                FROM order_items oi
                JOIN products p ON p.id = oi."productId"
                WHERE oi."orderId" = ANY(:ids)
                """;
        var params = new MapSqlParameterSource("ids", orderIds.toArray(new Integer[0]));
        List<Map<String, Object>> rows = jdbc.queryForList(sql, params);
        Map<Integer, List<OrderItemDTO>> result = new HashMap<>();
        for (var row : rows) {
            int orderId = ((Number) row.get("orderId")).intValue();
            int pid = ((Number) row.get("productId")).intValue();
            result.computeIfAbsent(orderId, k -> new ArrayList<>()).add(new OrderItemDTO(
                    ((Number) row.get("id")).intValue(),
                    pid,
                    ((Number) row.get("quantity")).intValue(),
                    (BigDecimal) row.get("unitPrice"),
                    (BigDecimal) row.get("discount"),
                    new OrderItemDTO.ProductSummaryDTO(pid, (String) row.get("sku"), (String) row.get("p_name"))));
        }
        return result;
    }

    private String formatTs(Object ts) {
        if (ts == null) return null;
        if (ts instanceof LocalDateTime ldt) return ISO.format(ldt);
        return ts.toString();
    }

    private long cachedCount(String countSql, MapSqlParameterSource params, String cacheKey) {
        try {
            List<Long> hit = jdbc.queryForList(
                "SELECT total FROM count_cache WHERE cache_key = :k AND cached_at > NOW() - INTERVAL '30 days'",
                new MapSqlParameterSource("k", cacheKey), Long.class);
            if (!hit.isEmpty()) return hit.get(0);
        } catch (Exception ignored) {}

        long total = Objects.requireNonNull(jdbc.queryForObject(countSql, params, Long.class));

        try {
            jdbc.update(
                "INSERT INTO count_cache (cache_key, total, cached_at) VALUES (:k, :t, NOW()) " +
                "ON CONFLICT (cache_key) DO UPDATE SET total = :t, cached_at = NOW()",
                new MapSqlParameterSource("k", cacheKey).addValue("t", total));
        } catch (Exception ignored) {}

        return total;
    }

    private String buildCountCacheKey(String q, String status, String regionCode,
                                      String from, String to,
                                      BigDecimal minTotal, BigDecimal maxTotal) {
        return "q=" + (q != null ? q.strip().toLowerCase() : "") +
               "&status=" + (status != null ? status : "") +
               "&regionCode=" + (regionCode != null ? regionCode : "") +
               "&from=" + (from != null ? from : "") +
               "&to=" + (to != null ? to : "") +
               "&minTotal=" + (minTotal != null ? minTotal.toPlainString() : "") +
               "&maxTotal=" + (maxTotal != null ? maxTotal.toPlainString() : "");
    }
}
