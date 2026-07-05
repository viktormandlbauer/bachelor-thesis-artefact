package at.thesis.poc.management.messaging;

import java.time.Instant;
import java.time.format.DateTimeParseException;

import at.thesis.poc.management.domain.MessageRecord;
import io.vertx.core.json.JsonObject;

/**
 * Event schema (plan §5.1): JSON body of every AMQP message on case.inbound/case.outbound.
 * Parsing fails loudly on malformed events so broker redelivery and DLQ routing apply (§6.2).
 */
public final class CaseEvents {

    public static final String ADDRESS_INBOUND = "case.inbound";
    public static final String ADDRESS_OUTBOUND = "case.outbound";
    public static final String DIRECTION_INBOUND = "inbound";
    public static final String DIRECTION_OUTBOUND = "outbound";
    public static final String AUTHOR_SUBMISSION = "submission";
    public static final String AUTHOR_MANAGEMENT = "management";

    /**
     * Demo hook for the resilience check (plan §8.5): a message with this body makes the
     * consumer throw, so bounded redelivery and DLQ routing can be demonstrated end to end.
     */
    public static final String POISON_MARKER = "__poison__";

    private CaseEvents() {
    }

    public record CaseEvent(String eventId, String caseId, String direction, String author,
                            long seq, String body, Instant createdAt) {
    }

    public static JsonObject toJson(MessageRecord message) {
        return new JsonObject()
                .put("eventId", message.eventId())
                .put("caseId", message.caseId())
                .put("direction", message.direction())
                .put("author", message.author())
                .put("seq", message.seq())
                .put("body", message.body())
                .put("createdAt", message.createdAt().toString());
    }

    public static CaseEvent parse(JsonObject json) {
        if (json == null) {
            throw new IllegalArgumentException("Case event payload is missing");
        }
        String eventId = requireText(json, "eventId");
        String caseId = requireText(json, "caseId");
        String direction = requireText(json, "direction");
        if (!DIRECTION_INBOUND.equals(direction) && !DIRECTION_OUTBOUND.equals(direction)) {
            throw new IllegalArgumentException("Case event has invalid direction: " + direction);
        }
        String author = requireText(json, "author");
        String body = requireText(json, "body");
        Long seq = json.getLong("seq");
        if (seq == null) {
            throw new IllegalArgumentException("Case event field is missing: seq");
        }
        Instant createdAt;
        try {
            createdAt = Instant.parse(requireText(json, "createdAt"));
        } catch (DateTimeParseException e) {
            throw new IllegalArgumentException("Case event has invalid createdAt", e);
        }
        return new CaseEvent(eventId, caseId, direction, author, seq, body, createdAt);
    }

    private static String requireText(JsonObject json, String field) {
        String value = json.getString(field);
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException("Case event field is missing: " + field);
        }
        return value;
    }
}
