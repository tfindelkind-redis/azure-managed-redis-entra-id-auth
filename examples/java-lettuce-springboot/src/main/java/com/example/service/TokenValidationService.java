package com.example.service;

import com.azure.core.credential.AccessToken;
import com.azure.core.credential.TokenRequestContext;
import com.azure.identity.ManagedIdentityCredential;
import com.azure.identity.ManagedIdentityCredentialBuilder;
import jakarta.annotation.PostConstruct;
import org.apache.hc.client5.http.classic.methods.HttpHead;
import org.apache.hc.client5.http.impl.classic.CloseableHttpClient;
import org.apache.hc.client5.http.impl.classic.HttpClients;
import org.apache.hc.core5.http.ClassicHttpResponse;
import org.apache.hc.core5.http.Header;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;

import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.Base64;

/**
 * Service for validating tokens and detecting clock skew issues.
 * 
 * IMPORTANT: Clock skew is a common cause of Entra ID authentication failures!
 * 
 * Symptoms of clock skew:
 * - Tokens appear to be expired even though they were just issued
 * - Token "not before" (nbf) claim is in the future
 * - Intermittent authentication failures
 * - Token expiration dates are in the past when you fetch them
 * 
 * This service helps diagnose these issues by:
 * 1. Comparing local time to Azure's time
 * 2. Validating token timestamps
 * 3. Providing detailed logging for troubleshooting
 */
@Service
public class TokenValidationService {

    private static final Logger log = LoggerFactory.getLogger(TokenValidationService.class);
    private static final String REDIS_SCOPE = "https://redis.azure.com/.default";

    @Value("${azure.identity.client-id}")
    private String managedIdentityClientId;

    private ManagedIdentityCredential credential;

    @PostConstruct
    public void init() {
        log.info("Initializing TokenValidationService");
        
        this.credential = new ManagedIdentityCredentialBuilder()
            .clientId(managedIdentityClientId)
            .build();
        
        // Check clock skew on startup
        checkClockSkew();
        
        // Validate initial token
        validateToken();
    }

    /**
     * Checks for clock skew between the local system and Azure.
     * 
     * Azure tokens include timestamps (iat, nbf, exp) that are validated server-side.
     * If your system clock is off by more than a few minutes, authentication will fail.
     */
    public void checkClockSkew() {
        log.info("Checking clock skew with Azure...");
        
        Instant localTime = Instant.now();
        Instant azureTime = null;
        
        try (CloseableHttpClient client = HttpClients.createDefault()) {
            // Query Azure's time from a well-known endpoint
            HttpHead request = new HttpHead("https://management.azure.com/");
            
            try (ClassicHttpResponse response = client.execute(request, resp -> resp)) {
                Header dateHeader = response.getFirstHeader("Date");
                if (dateHeader != null) {
                    // Parse the HTTP date header
                    String dateStr = dateHeader.getValue();
                    azureTime = DateTimeFormatter.RFC_1123_DATE_TIME
                        .parse(dateStr, Instant::from);
                }
            }
        } catch (Exception e) {
            log.warn("Could not check Azure time: {}", e.getMessage());
            return;
        }
        
        if (azureTime != null) {
            Duration skew = Duration.between(localTime, azureTime);
            long skewSeconds = Math.abs(skew.getSeconds());
            
            if (skewSeconds > 300) { // More than 5 minutes
                log.error("⚠️  CRITICAL CLOCK SKEW DETECTED!");
                log.error("   Local time:  {}", localTime);
                log.error("   Azure time:  {}", azureTime);
                log.error("   Skew:        {} seconds ({} minutes)", skewSeconds, skewSeconds / 60);
                log.error("");
                log.error("   This will cause Entra ID authentication to fail!");
                log.error("   Please synchronize your system clock using NTP.");
                log.error("");
                log.error("   On Linux: sudo timedatectl set-ntp true");
                log.error("   On Azure VMs: Ensure Azure Guest Agent is running");
            } else if (skewSeconds > 60) { // More than 1 minute
                log.warn("⚠️  Clock skew warning: {} seconds", skewSeconds);
                log.warn("   Local time: {}", localTime);
                log.warn("   Azure time: {}", azureTime);
            } else {
                log.info("✅ Clock skew is acceptable: {} seconds", skewSeconds);
            }
        }
    }

    /**
     * Validates and logs token details.
     */
    public void validateToken() {
        log.info("Fetching and validating Entra ID token...");
        
        try {
            TokenRequestContext context = new TokenRequestContext()
                .addScopes(REDIS_SCOPE);
            
            AccessToken token = credential.getToken(context).block();
            
            if (token == null) {
                log.error("❌ Failed to obtain token - null response");
                return;
            }
            
            Instant now = Instant.now();
            OffsetDateTime expiresAt = token.getExpiresAt();
            
            // Parse the JWT to get more details
            String[] parts = token.getToken().split("\\.");
            if (parts.length >= 2) {
                String payloadJson = new String(Base64.getUrlDecoder().decode(parts[1]));
                log.debug("Token payload: {}", payloadJson);
                
                // Extract claims manually (or use a JWT library)
                // For simplicity, we'll just log what we can from the AccessToken
            }
            
            // Check if token is already expired
            if (expiresAt.toInstant().isBefore(now)) {
                long secondsAgo = Duration.between(expiresAt.toInstant(), now).getSeconds();
                log.error("❌ TOKEN IS ALREADY EXPIRED!");
                log.error("   Expires at: {}", expiresAt);
                log.error("   Current time: {}", now.atOffset(ZoneOffset.UTC));
                log.error("   Expired {} seconds ago", secondsAgo);
                log.error("");
                log.error("   This indicates a CLOCK SKEW issue!");
                log.error("   Your system clock appears to be ahead of Azure's time.");
                checkClockSkew();
            } else {
                Duration validFor = Duration.between(now, expiresAt.toInstant());
                log.info("✅ Token is valid");
                log.info("   Expires at: {}", expiresAt);
                log.info("   Valid for: {} minutes", validFor.toMinutes());
                
                if (validFor.toMinutes() < 5) {
                    log.warn("   ⚠️  Token expires soon! Ensure token refresh is working.");
                }
            }
            
        } catch (Exception e) {
            log.error("❌ Token validation failed: {}", e.getMessage(), e);
        }
    }

    /**
     * Periodically validate token health.
     */
    @Scheduled(fixedRate = 300000) // Every 5 minutes
    public void periodicValidation() {
        log.debug("Running periodic token validation");
        validateToken();
    }
}
