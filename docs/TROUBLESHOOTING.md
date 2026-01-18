# Troubleshooting Entra ID Authentication with Azure Managed Redis

This guide covers common issues and solutions when using Entra ID authentication with Azure Managed Redis.

## 🔥 Most Common Issues

### 1. Clock Skew (Token Expiration in the Past)

**Symptoms:**
- Tokens appear expired immediately after fetching
- Token expiration dates are in the past
- Error: "Token validation failed" or "Token expired"
- Intermittent authentication failures that seem random

**Root Cause:**
Entra ID tokens contain timestamps (`iat` - issued at, `nbf` - not before, `exp` - expiry) that Azure validates against its own clock. If your system's clock is more than 5 minutes out of sync, authentication will fail.

**Diagnosis:**
```bash
# Check your system time vs Azure time
date -u
curl -sI https://management.azure.com/ | grep -i date
```

**Solution:**
```bash
# On Linux - Enable NTP synchronization
sudo timedatectl set-ntp true
sudo systemctl restart systemd-timesyncd

# Verify
timedatectl status

# On Azure VMs - Ensure Azure Guest Agent is running
sudo systemctl status waagent

# On Container Apps/AKS - Usually handled automatically, but verify
kubectl exec -it <pod> -- date -u
```

**Java Code to Detect Clock Skew:**
```java
// Compare local time to Azure time
Instant localTime = Instant.now();
HttpURLConnection conn = (HttpURLConnection) 
    new URL("https://management.azure.com/").openConnection();
conn.setRequestMethod("HEAD");
String azureDateStr = conn.getHeaderField("Date");
// Parse and compare...
```

---

### 2. Connection Refused to Internal IPs (Cluster Mode)

**Symptoms:**
- `Connection refused: /10.0.0.5:10000`
- Connections to 10.x.x.x, 172.x.x.x, or 192.168.x.x addresses
- Works initially, then fails after cluster operations
- Topology refresh failures

**Root Cause:**
Azure Managed Redis (Cluster OSS) nodes advertise their internal IP addresses in `CLUSTER SLOTS` responses. Your client tries to connect directly to these internal IPs, which are not reachable from outside the cluster.

**Solution: MappingSocketAddressResolver (Lettuce)**
```java
MappingSocketAddressResolver resolver = MappingSocketAddressResolver.create(
    DnsResolver.unresolved(),
    hostAndPort -> {
        String host = hostAndPort.getHostText();
        // Map internal IPs back to the public hostname
        if (host.startsWith("10.") || host.startsWith("172.") || 
            host.startsWith("192.168.")) {
            return HostAndPort.of(publicHostname, hostAndPort.getPort());
        }
        return hostAndPort;
    }
);

ClientResources resources = ClientResources.builder()
    .socketAddressResolver(resolver)
    .build();
```

**Solution: Jedis**
```java
// Jedis uses JedisClusterHostAndPortMap
public class AzureHostAndPortMap implements JedisClusterHostAndPortMap {
    private final String publicHostname;
    
    @Override
    public HostAndPort getSSLHostAndPort(String host, int port) {
        // Always return the public hostname
        return new HostAndPort(publicHostname, port);
    }
}
```

---

### 3. Access Policy Not Found / Wrong OID

**Symptoms:**
- `NOAUTH Authentication required`
- `WRONGPASS invalid username-password pair`
- Token is valid but authentication still fails

**Root Cause:**
The Object ID (OID) in your Entra ID token doesn't match any access policy in Azure Managed Redis.

**Diagnosis:**
1. Decode your JWT token (use jwt.ms or jwt.io)
2. Find the `oid` claim
3. Compare with access policies in Azure portal

```bash
# Get the OID from your token
echo $TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | jq '.oid'

# For Managed Identity, get the Object ID
az identity show --name <identity-name> --resource-group <rg> --query principalId -o tsv
```

**Solution:**
```bash
# Create access policy using the correct OID
az redis access-policy-assignment create \
    --name "<unique-name>" \
    --resource-group "<rg>" \
    --cache-name "<redis-name>" \
    --access-policy-name "Data Owner" \
    --object-id "<oid-from-token>" \
    --object-id-alias "<alias>"
```

**Common Mistakes:**
- Using the **Client ID** instead of **Object ID** (Principal ID)
- Using the App Registration's Object ID instead of the Service Principal's Object ID
- For User-Assigned Managed Identity: use the **Principal ID** from the identity, not the Client ID

---

### 4. Token Refresh Failures

**Symptoms:**
- Connection works initially, then fails after ~1 hour
- `Token expired` errors
- AUTH errors in cluster operations

**Root Cause:**
Entra ID tokens expire after ~1 hour. If token refresh isn't configured, the connection will fail.

**Solution (Lettuce):**
```java
ClientOptions options = ClientOptions.builder()
    .reauthenticateBehavior(ClientOptions.ReauthenticateBehavior.ON_NEW_CREDENTIALS)
    .build();
```

**Solution (Jedis):**
```java
JedisPooled jedis = new JedisPooled(
    /* ... */,
    new DefaultJedisClientConfig.Builder()
        .credentialsProvider(entraIdCredentialsProvider)
        .build()
);
// The credentials provider handles refresh automatically
```

**Solution (node-redis):**
```javascript
const provider = EntraIdCredentialsProviderFactory.createForClientCredentials({
    // ... config ...
    tokenManagerConfig: {
        expirationRefreshRatio: 0.8,  // Refresh at 80% of lifetime
    }
});
```

---

### 5. SSL/TLS Certificate Errors

**Symptoms:**
- `SSL handshake failed`
- `Certificate verification failed`
- `PKIX path building failed`

**Root Cause:**
Azure Managed Redis uses TLS certificates signed by Microsoft's CA. If your system doesn't trust these CAs, connections will fail.

**Solution (Java):**
```java
// Usually not needed, but if you have a custom truststore:
System.setProperty("javax.net.ssl.trustStore", "/path/to/truststore.jks");

// Or in RedisURI
RedisURI uri = RedisURI.builder()
    .withSsl(true)
    .withVerifyPeer(true)  // Keep this true!
    .build();
```

**Solution (Node.js):**
```javascript
const client = createClient({
    socket: {
        tls: true,
        // Don't disable certificate verification in production!
        // rejectUnauthorized: false  // NEVER DO THIS IN PRODUCTION
    }
});
```

---

### 6. Managed Identity Not Available

**Symptoms:**
- `ManagedIdentityCredential authentication failed`
- `IMDS endpoint not available`
- Works locally but fails in Azure

**Root Cause:**
The application is running in an environment where managed identity is not available, or the identity is not properly attached.

**Diagnosis:**
```bash
# Test if IMDS is available (from Azure VM/Container)
curl -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://redis.azure.com/"

# Check attached identities
az vm identity show --name <vm-name> --resource-group <rg>
az containerapp identity show --name <app-name> --resource-group <rg>
```

**Common Issues:**
- Identity not attached to VM/Container App/AKS pod
- Using System-Assigned but configured for User-Assigned (or vice versa)
- IMDS endpoint blocked by network rules
- Running locally (use Service Principal instead)

---

## 🔧 Debug Logging

### Enable Debug Logging (Java/Lettuce)
```yaml
logging:
  level:
    io.lettuce.core: DEBUG
    redis.clients.authentication: DEBUG
    com.azure.identity: DEBUG
```

### Enable Debug Logging (Node.js)
```javascript
process.env.DEBUG = 'redis:*,@redis/entraid:*';
```

### Enable Debug Logging (Python)
```python
import logging
logging.basicConfig(level=logging.DEBUG)
logging.getLogger('azure.identity').setLevel(logging.DEBUG)
logging.getLogger('redis').setLevel(logging.DEBUG)
```

---

## 📋 Diagnostic Checklist

Before opening a support ticket, verify:

- [ ] **Clock is synchronized** (within 5 minutes of Azure time)
- [ ] **OID matches access policy** (decode JWT, compare `oid` claim)
- [ ] **Correct identity type** (System vs User-Assigned Managed Identity)
- [ ] **Identity attached to compute** (VM, Container App, AKS, etc.)
- [ ] **Access policy exists** with correct OID and permissions
- [ ] **SSL/TLS enabled** (`useSsl: true` or equivalent)
- [ ] **Correct port** (typically 10000 for Azure Managed Redis)
- [ ] **Network connectivity** (firewall rules, VNet, Private Endpoint)
- [ ] **Token refresh configured** (for connections > 1 hour)
- [ ] **Address resolver configured** (for cluster mode)

---

## 🆘 Getting Help

If issues persist:

1. **Collect logs** with debug logging enabled
2. **Decode your token** at https://jwt.ms (don't share the full token!)
3. **Check Azure Activity Log** for access policy changes
4. **Review Redis metrics** in Azure portal
5. **Open a support case** with Microsoft if needed
