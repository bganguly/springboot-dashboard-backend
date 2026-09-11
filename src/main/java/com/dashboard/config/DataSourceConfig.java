package com.dashboard.config;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import javax.sql.DataSource;

@Configuration
public class DataSourceConfig {

    private static final Logger log = LoggerFactory.getLogger(DataSourceConfig.class);

    @Bean
    public DataSource dataSource(@Value("${DATABASE_URL}") String databaseUrl) {
        // Parse postgresql://user:pass@host:port/db — credentials must NOT be embedded
        // in the JDBC URL because PostgreSQL JDBC 42.7.x treats "user:pass@host" as
        // the hostname, causing an UnknownHostException.
        String raw = databaseUrl.startsWith("postgresql://") ? databaseUrl
                : databaseUrl.substring("jdbc:postgresql://".length() - "postgresql://".length());
        String noScheme = raw.substring("postgresql://".length()); // user:pass@host:port/db
        int atIdx = noScheme.indexOf('@');
        String userInfo   = noScheme.substring(0, atIdx);
        String hostAndDb  = noScheme.substring(atIdx + 1);          // host:port/db
        int colonIdx = userInfo.indexOf(':');
        String user     = userInfo.substring(0, colonIdx);
        String password = userInfo.substring(colonIdx + 1);
        // Preserve sslmode from URL if present (e.g. Neon requires sslmode=require).
        // Only default to sslmode=disable for GCE Postgres on private VPC.
        String jdbcUrl = "jdbc:postgresql://" + hostAndDb;
        if (!hostAndDb.contains("sslmode=")) {
            jdbcUrl += (hostAndDb.contains("?") ? "&" : "?") + "sslmode=disable";
        }
        if (!hostAndDb.contains("currentSchema=") && !hostAndDb.contains("search_path=")) {
            jdbcUrl += "&currentSchema=public";
        }
        log.info("DataSource: jdbc:postgresql://{} user={}", hostAndDb, user);
        var config = new HikariConfig();
        config.setJdbcUrl(jdbcUrl);
        config.setUsername(user);
        config.setPassword(password);
        config.setMaximumPoolSize(10);
        config.setMinimumIdle(2);
        config.setConnectionTimeout(30_000);
        config.setInitializationFailTimeout(-1);
        return new HikariDataSource(config);
    }
}
