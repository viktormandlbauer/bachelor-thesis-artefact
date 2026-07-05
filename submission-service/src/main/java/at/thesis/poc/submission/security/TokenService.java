package at.thesis.poc.submission.security;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.Base64;

import jakarta.enterprise.context.ApplicationScoped;

/**
 * Case access tokens: 256 bits of entropy, returned to the client exactly once.
 * Only the SHA-256 hash is kept in memory; comparison is constant-time (plan §6.3).
 * Tokens must never appear in logs, spans, AMQP messages, or exception messages.
 */
@ApplicationScoped
public class TokenService {

    private static final SecureRandom RANDOM = new SecureRandom();

    public String generate() {
        byte[] bytes = new byte[32];
        RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    public byte[] hash(String token) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(token.getBytes(StandardCharsets.UTF_8));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 unavailable", e);
        }
    }

    public boolean matches(String presentedToken, byte[] storedHash) {
        if (presentedToken == null || presentedToken.isBlank() || storedHash == null) {
            return false;
        }
        return MessageDigest.isEqual(storedHash, hash(presentedToken));
    }
}
