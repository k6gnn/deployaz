package az.deployaz.demo;

import org.springframework.boot.actuate.health.Health;
import org.springframework.boot.actuate.health.HealthIndicator;
import org.springframework.stereotype.Component;

/**
 * Contributes a "dbPassword" section to /actuator/health -- reachable only
 * on the management port (:8081, see application.yml), which is not exposed
 * through the Service/Ingress and is blocked from external traffic by the
 * NetworkPolicy. Only the monitoring namespace (Prometheus) and kubelet
 * probes can reach it.
 *
 * Reports presence only ("configured": true/false) -- never the secret value.
 */
@Component
public class DbPasswordHealthIndicator implements HealthIndicator {

    private final SecretStartupCheck secretStartupCheck;

    public DbPasswordHealthIndicator(SecretStartupCheck secretStartupCheck) {
        this.secretStartupCheck = secretStartupCheck;
    }

    @Override
    public Health health() {
        if (!secretStartupCheck.isRequired()) {
            // CI/local dev: no secret expected, nothing to report.
            return Health.up()
                    .withDetail("configured", false)
                    .withDetail("required", false)
                    .build();
        }
        // If required=true and we got this far without SecretStartupCheck
        // having thrown, the secret is present -- the app wouldn't be
        // running otherwise. This just makes that fact visible.
        return Health.up()
                .withDetail("configured", secretStartupCheck.isSecretPresent())
                .withDetail("required", true)
                .build();
    }
}
