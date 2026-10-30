package com.dashboard.controller;

import com.dashboard.service.AggregateService;
import com.dashboard.service.AggregatesCache;
import com.dashboard.service.OrderService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.math.BigDecimal;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;

@RestController
@RequestMapping("/api/aggregates")
@RequiredArgsConstructor
public class AggregateController {

    private final AggregateService aggregateService;
    private final AggregatesCache aggregatesCache;
    private final Executor virtualThreadExecutor = java.util.concurrent.Executors.newVirtualThreadPerTaskExecutor();

    @GetMapping
    public ResponseEntity<?> get(
            @RequestParam String from,
            @RequestParam String to,
            @RequestParam(required = false) String q,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String regionCode,
            @RequestParam(required = false) BigDecimal minTotal,
            @RequestParam(required = false) BigDecimal maxTotal,
            @RequestParam(required = false) Integer topCategories,
            @RequestParam(defaultValue = "true") boolean includeData,
            @RequestParam(defaultValue = "true") boolean includeTotal) {

        boolean noFilters = (q == null || q.isBlank())
                && (status == null || status.isBlank())
                && (regionCode == null || regionCode.isBlank())
                && minTotal == null && maxTotal == null;
        int topN = topCategories != null ? topCategories : 5;

        if (noFilters && includeData && includeTotal) {
            var cached = aggregatesCache.get(AggregatesCache.key(from, to, topN));
            if (cached.isPresent()) return ResponseEntity.ok(cached.get());
        }

        CompletableFuture<?> dataFuture = includeData
                ? CompletableFuture.supplyAsync(
                        () -> aggregateService.getDailyAggregates(from, to, q, status, regionCode, minTotal, maxTotal, topCategories),
                        virtualThreadExecutor)
                : CompletableFuture.completedFuture(null);
        CompletableFuture<?> totalFuture = includeTotal
                ? CompletableFuture.supplyAsync(
                        () -> aggregateService.getExactTotal(from, to, q, status, regionCode, minTotal, maxTotal),
                        virtualThreadExecutor)
                : CompletableFuture.completedFuture(null);

        var data = dataFuture.join();
        var totalOrders = totalFuture.join();

        Map<String, Object> body = new HashMap<>();
        if (includeData) body.put("data", data);
        if (includeTotal) {
            long raw = (Long) totalOrders;
            body.put("totalOrders", OrderService.adjustCount(raw));
            body.put("totalOrdersApproximate", OrderService.isApproximateCount(raw));
        }

        if (noFilters && includeData && includeTotal) {
            aggregatesCache.put(AggregatesCache.key(from, to, topN), body);
        }

        return ResponseEntity.ok(body);
    }
}
