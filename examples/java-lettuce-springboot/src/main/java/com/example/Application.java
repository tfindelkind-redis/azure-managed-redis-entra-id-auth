package com.example;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.ConfigurableApplicationContext;

/**
 * Spring Boot Application demonstrating Azure Managed Redis (Cluster OSS)
 * with Entra ID authentication using Lettuce.
 * 
 * Key features demonstrated:
 * 1. Cluster connection with MappingSocketAddressResolver (critical for AMR!)
 * 2. User-Assigned Managed Identity authentication
 * 3. Automatic token refresh with ON_NEW_CREDENTIALS behavior
 * 4. Clock skew detection and troubleshooting
 * 
 * Note: This is a demo app that exits after running tests.
 * For production apps, remove System.exit(0) to keep the app running.
 */
@SpringBootApplication
public class Application {
    
    public static void main(String[] args) {
        ConfigurableApplicationContext context = SpringApplication.run(Application.class, args);
        // Exit after demo completes - remove this for production apps that need to keep running
        System.exit(0);
    }
}
