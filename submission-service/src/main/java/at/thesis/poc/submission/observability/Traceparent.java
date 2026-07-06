package at.thesis.poc.submission.observability;

import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.api.trace.TraceFlags;
import io.opentelemetry.api.trace.TraceState;

/**
 * W3C traceparent round-trip (plan §7): the trace context is persisted as a traceparent
 * string with each outbox row and message, and restored when the relay publishes or a
 * later action in the same case adds a span link. tracestate is not round-tripped in
 * this phase (column exists, stays null).
 */
public final class Traceparent {

    private Traceparent() {
    }

    public static String of(SpanContext context) {
        if (context == null || !context.isValid()) {
            return null;
        }
        return "00-" + context.getTraceId() + "-" + context.getSpanId()
                + "-" + context.getTraceFlags().asHex();
    }

    /** Returns an invalid SpanContext for null/malformed input; callers must check isValid(). */
    public static SpanContext parse(String traceparent) {
        if (traceparent == null) {
            return SpanContext.getInvalid();
        }
        String[] parts = traceparent.split("-");
        if (parts.length != 4) {
            return SpanContext.getInvalid();
        }
        try {
            return SpanContext.createFromRemoteParent(
                    parts[1], parts[2], TraceFlags.fromHex(parts[3], 0), TraceState.getDefault());
        } catch (RuntimeException e) {
            return SpanContext.getInvalid();
        }
    }
}
