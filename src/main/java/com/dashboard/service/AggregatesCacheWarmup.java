package com.dashboard.service;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

/**
 * Pre-warms the in-process aggregates cache on startup with the all-time and
 * last-90-day views using the actual data date range from daily_summary.
 * Runs on a virtual thread so startup is not blocked.
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class AggregatesCacheWarmup implements ApplicationRunner {

    private static final int DEFAULT_TOP_N = 4;

    private final AggregateService aggregateService;
    private final AggregatesCache aggregatesCache;
    private final NamedParameterJdbcTemplate jdbc;

    @Override
    public void run(ApplicationArguments args) {
        Thread.ofVirtual().name("aggregates-cache-warmup").start(this::warmup);
    }

    private void warmup() {
        try {
            var range = jdbc.queryForMap(
                    "SELECT MIN(date)::text AS min_date, MAX(date)::text AS max_date FROM daily_summary",
                    Collections.emptyMap());
            String minDate = (String) range.get("min_date");
            String maxDate = (String) range.get("max_date");
            if (minDate == null || maxDate == null) {
                log.warn("AggregatesCacheWarmup: daily_summary empty — skipping");
                return;
            }
            String from90 = java.time.LocalDate.parse(maxDate).minusDays(89).toString();

            warmOne(minDate, maxDate, DEFAULT_TOP_N);
            warmOne(from90, maxDate, DEFAULT_TOP_N);
        } catch (Exception e) {
            log.warn("AggregatesCacheWarmup: failed (non-fatal): {}", e.getMessage());
        }
    }

    private void warmOne(String from, String to, int topN) {
        log.info("AggregatesCacheWarmup: warming {}/{} topN={}", from, to, topN);
        var data = aggregateService.getDailyAggregates(from, to, null, null, null, null, null, topN);
        long rawTotal = aggregateService.getExactTotal(from, to, null, null, null, null, null);
        Map<String, Object> body = new HashMap<>();
        body.put("data", data);
        body.put("totalOrders", OrderService.adjustCount(rawTotal));
        body.put("totalOrdersApproximate", OrderService.isApproximateCount(rawTotal));
        aggregatesCache.put(AggregatesCache.key(from, to, topN), body);
        log.info("AggregatesCacheWarmup: done {}/{} — {} day-buckets, total={}", from, to, data.size(), body.get("totalOrders"));
    }
}
