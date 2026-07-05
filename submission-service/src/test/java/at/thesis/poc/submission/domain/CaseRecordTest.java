package at.thesis.poc.submission.domain;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

import java.time.Instant;
import java.util.List;

import org.junit.jupiter.api.Test;

class CaseRecordTest {

    private static final Instant T0 = Instant.parse("2026-01-15T10:00:00Z");

    private static MessageRecord message(String eventId, String direction, Instant createdAt) {
        return new MessageRecord(eventId, "case-1", direction, "submission", 1, "text", createdAt);
    }

    @Test
    void messagesAreOrderedByCreatedAtThenEventId() {
        CaseRecord record = new CaseRecord("case-1", new byte[32], T0);
        record.append(message("bbb", "inbound", T0.plusSeconds(10)));
        record.append(message("zzz", "inbound", T0));
        // same timestamp as bbb -> eventId tie-break
        record.append(message("aaa", "inbound", T0.plusSeconds(10)));

        List<String> order = record.sortedMessages().stream().map(MessageRecord::eventId).toList();
        assertEquals(List.of("zzz", "aaa", "bbb"), order);
    }

    @Test
    void updatedAtTracksLatestMessage() {
        CaseRecord record = new CaseRecord("case-1", new byte[32], T0);
        record.append(message("a", "inbound", T0.plusSeconds(60)));
        assertEquals(T0.plusSeconds(60), record.updatedAt());
        // an older message must not move updatedAt backwards
        record.append(message("b", "outbound", T0.plusSeconds(30)));
        assertEquals(T0.plusSeconds(60), record.updatedAt());
    }

    @Test
    void latestTraceContextFiltersByDirection() {
        CaseRecord record = new CaseRecord("case-1", new byte[32], T0);
        MessageRecord older = message("a", "outbound", T0);
        older.traceContext(new TraceContextRef("0af7651916cd43dd8448eb211c80319c", "b7ad6b7169203331", "01", ""));
        MessageRecord newer = message("b", "outbound", T0.plusSeconds(5));
        newer.traceContext(new TraceContextRef("1af7651916cd43dd8448eb211c80319c", "c7ad6b7169203331", "01", ""));
        MessageRecord inbound = message("c", "inbound", T0.plusSeconds(10));
        record.append(older);
        record.append(newer);
        record.append(inbound);

        assertEquals("1af7651916cd43dd8448eb211c80319c", record.latestTraceContext("outbound").traceId());
        assertNull(record.latestTraceContext("inbound"), "inbound message has no stored context");
    }

    @Test
    void stagedCaseIsInvisibleUntilCommitted() {
        CaseStore store = new CaseStore();
        CaseRecord staged = new CaseRecord("case-1", new byte[32], T0);
        // commit-after-publish: nothing visible before the broker accepted the event
        assertNull(store.get("case-1"));
        store.commit(staged);
        assertEquals(staged, store.get("case-1"));
    }
}
