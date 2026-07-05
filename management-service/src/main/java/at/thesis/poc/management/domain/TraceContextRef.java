package at.thesis.poc.management.domain;

import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.api.trace.TraceFlags;
import io.opentelemetry.api.trace.TraceState;

/**
 * Immutable snapshot of an OpenTelemetry span context, stored next to each message
 * record so later user actions in the same case can add span links back to the most
 * recent related event (conversation-correlated trace graph, plan §5.4).
 */
public record TraceContextRef(String traceId, String spanId, String traceFlags, String traceState) {

    public static TraceContextRef from(SpanContext context) {
        if (context == null || !context.isValid()) {
            return null;
        }
        return new TraceContextRef(
                context.getTraceId(),
                context.getSpanId(),
                context.getTraceFlags().asHex(),
                "");
    }

    /** Rebuilds a span-link target. Trace state is not round-tripped in Phase 1. */
    public SpanContext toSpanContext() {
        return SpanContext.createFromRemoteParent(
                traceId,
                spanId,
                TraceFlags.fromHex(traceFlags, 0),
                TraceState.getDefault());
    }
}
