package at.thesis.poc.submission.observability;

import io.opentelemetry.api.trace.Span;

/**
 * Mandatory correlation attributes for the conversation-correlated trace graph (plan §5.4):
 * domain attributes (case.id, conversation.id, event.id, message.*) plus the OpenTelemetry
 * messaging semantic-convention attributes, emitted side by side.
 */
public final class TraceAttributes {

    public static final String MESSAGING_SYSTEM = "activemq";

    private TraceAttributes() {
    }

    public static void annotate(Span span, String caseId, String eventId,
                                String direction, String author, String destination) {
        if (span == null || !span.getSpanContext().isValid()) {
            return;
        }
        if (caseId != null) {
            span.setAttribute("case.id", caseId);
            span.setAttribute("conversation.id", caseId);
            span.setAttribute("messaging.message.conversation_id", caseId);
        }
        if (eventId != null) {
            span.setAttribute("event.id", eventId);
            span.setAttribute("messaging.message.id", eventId);
        }
        if (direction != null) {
            span.setAttribute("message.direction", direction);
        }
        if (author != null) {
            span.setAttribute("message.author", author);
        }
        if (destination != null) {
            span.setAttribute("messaging.destination.name", destination);
            span.setAttribute("messaging.system", MESSAGING_SYSTEM);
        }
    }
}
