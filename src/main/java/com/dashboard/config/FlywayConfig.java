package com.dashboard.config;

import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationInfo;
import org.springframework.boot.flyway.autoconfigure.FlywayMigrationStrategy;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class FlywayConfig {

    @Bean
    public FlywayMigrationStrategy resetOnStaleBaseline() {
        return flyway -> {
            // Only touch anything when Flyway has no REAL history yet (table
            // absent, or present with only a BASELINE row). A database that
            // already has genuine migration history — e.g. prod, managed by
            // Flyway from day one — must be left completely alone: calling
            // baseline() against it fails outright, which is exactly the
            // regression this guard exists to prevent.
            if (hasNoRealHistory(flyway)) {
                dropStaleHistoryTable(flyway);
                baselineIfDdlPreApplied(flyway);
            }
            // V9 is pre-inserted into flyway_schema_history at a higher
            // installed_rank than V10 (deploy.sh's Python sort assigns V10→rank1,
            // V9→rank10). Flyway 12 validate() treats this out-of-order position
            // as "not applied" when outOfOrder=false. Rebuild here to guarantee
            // both flags are set regardless of Spring Boot / Flyway API mapping.
            Flyway f = Flyway.configure()
                    .configuration(flyway.getConfiguration())
                    .outOfOrder(true)
                    .validateOnMigrate(false)
                    .load();
            f.repair();
            f.migrate();
        };
    }

    private boolean hasNoRealHistory(Flyway flyway) {
        try (var conn = flyway.getConfiguration().getDataSource().getConnection();
             var stmt = conn.createStatement()) {
            var rs = stmt.executeQuery(
                    "SELECT COUNT(*) FROM flyway_schema_history WHERE type != 'BASELINE'");
            rs.next();
            return rs.getInt(1) == 0;
        } catch (Exception e) {
            return true; // table absent — truly fresh DB
        }
    }

    // If flyway_schema_history contains only a BASELINE row (no versioned migrations),
    // the baseline was stamped on a fresh DB but the actual DDL was never executed.
    // Dropping it lets Flyway (or baselineIfDdlPreApplied below) treat the DB as new
    // instead of tripping over a table that "already exists, and is empty".
    private void dropStaleHistoryTable(Flyway flyway) {
        try (var conn = flyway.getConfiguration().getDataSource().getConnection();
             var stmt = conn.createStatement()) {
            stmt.execute("DROP TABLE flyway_schema_history");
        } catch (Exception ignored) {}
    }

    // local-dev.sh / prepare-demo-data.sh apply the V*.sql files directly via
    // psql (so seeding can run before the app's first boot). That leaves the
    // schema fully migrated but flyway_schema_history untouched. Baseline at
    // the highest known migration version so migrate() treats those versions
    // as already applied instead of re-running their (non-idempotent) DDL.
    private void baselineIfDdlPreApplied(Flyway flyway) {
        try (var conn = flyway.getConfiguration().getDataSource().getConnection();
             var stmt = conn.createStatement()) {
            stmt.executeQuery("SELECT 1 FROM \"orders\" LIMIT 1");
        } catch (Exception e) {
            return; // no pre-existing schema — let migrate() build it from scratch
        }

        MigrationInfo[] all = flyway.info().all();
        if (all.length == 0) return;
        var latest = all[all.length - 1].getVersion();

        Flyway.configure()
                .configuration(flyway.getConfiguration())
                .baselineVersion(latest)
                .baselineDescription("pre-applied outside Flyway")
                .load()
                .baseline();
    }
}
