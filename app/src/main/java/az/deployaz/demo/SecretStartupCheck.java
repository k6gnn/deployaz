package az.deployaz.demo;

import jakarta.annotation.PostConstruct;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Proves the secret actually landed in the pod, without ever exposing its
 * value anywhere -- not a log line, not an endpoint, not an exception message.
 *
 * When deployaz.secrets.require=false (default -- CI, local dev), this is a
 * no-op: no Vault agent is expected, so there's nothing to check.
 *
 * When deployaz.secrets.require=true (set only in k8s deployment manifests),
 * a missing or empty secret file throws on startup. Spring Boot's context
 * fails, the pod never reaches Running/Ready, and the readiness probe never
 * passes -- that failure *is* the proof, no custom code needed to report it.
 */
@Component
public class SecretStartupCheck {

    private final boolean required;
    private final Path secretPath;
    private volatile boolean secretPresent = false;

    public SecretStartupCheck(
            @Value("${deployaz.secrets.require:false}") boolean required,
            @Value("${deployaz.secrets.db-password-path:/vault/secrets/db-password}") String path) {
        this.required = required;
        this.secretPath = Path.of(path);
    }

    @PostConstruct
    void verifySecretIsPresent() {
        if (!required) {
            return;
        }
        String value;
        try {
            value = Files.readString(secretPath).trim();
        } catch (IOException e) {
            throw new IllegalStateException(
                    "deployaz.secrets.require=true but secret file was not readable at "
                            + secretPath + " -- refusing to start. Check Vault Agent Injector "
                            + "annotations and that this pod's ServiceAccount is bound to a Vault role.",
                    e);
        }
        if (value.isEmpty()) {
            throw new IllegalStateException(
                    "deployaz.secrets.require=true but secret file at " + secretPath
                            + " was empty -- refusing to start.");
        }
        this.secretPresent = true;
    }

    /** Used only to report presence (true/false), never the value itself. */
    public boolean isSecretPresent() {
        return secretPresent;
    }

    public boolean isRequired() {
        return required;
    }
}
