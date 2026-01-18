package com.example;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Spring Boot Application demonstrating Azure Managed Redis (Cluster OSS)
 * with Entra ID authentication using Lettuce.
 * 
 * Key features demonstrated:
 * 1. Cluster connection with MappingSocketAddressResolver (critical for AMR!)
 * 2. User-Assigned Managed Identity authentication
 * 3. Automatic token refresh with ON_NEW_CREDENTIALS behavior
 * 4. Clock skew detection and troubleshooting
 */
@SpringBootApplication
public class Application {
    
    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }
}
