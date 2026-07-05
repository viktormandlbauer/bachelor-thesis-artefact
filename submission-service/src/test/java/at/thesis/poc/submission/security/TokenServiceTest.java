package at.thesis.poc.submission.security;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class TokenServiceTest {

    private final TokenService tokens = new TokenService();

    @Test
    void generatedTokensCarry256BitsAndAreUnique() {
        String first = tokens.generate();
        String second = tokens.generate();
        // 32 random bytes -> 43 chars of unpadded base64url
        assertTrue(first.length() >= 43);
        assertNotEquals(first, second);
    }

    @Test
    void hashingIsDeterministic() {
        String token = tokens.generate();
        assertArrayEquals(tokens.hash(token), tokens.hash(token));
    }

    @Test
    void matchesAcceptsOnlyTheOriginalToken() {
        String token = tokens.generate();
        byte[] hash = tokens.hash(token);
        assertTrue(tokens.matches(token, hash));
        assertFalse(tokens.matches(token + "x", hash));
        assertFalse(tokens.matches("", hash));
        assertFalse(tokens.matches(null, hash));
        assertFalse(tokens.matches(token, null));
    }
}
