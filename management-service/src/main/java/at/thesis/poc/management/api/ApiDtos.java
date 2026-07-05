package at.thesis.poc.management.api;

import java.time.Instant;
import java.util.List;

import at.thesis.poc.management.domain.CaseRecord;
import at.thesis.poc.management.domain.MessageRecord;

/** Request/response payloads of the management API (plan §4.2). */
public final class ApiDtos {

    private ApiDtos() {
    }

    public record MessageRequest(String message) {
    }

    public record ReplyResponse(String caseId, String eventId, String status) {
    }

    public record CaseSummary(String caseId, String status, int messageCount,
                              Instant createdAt, Instant updatedAt) {

        static CaseSummary of(CaseRecord record) {
            return new CaseSummary(record.caseId(), record.status(), record.messageCount(),
                    record.createdAt(), record.updatedAt());
        }
    }

    public record MessageView(String eventId, String author, long seq, String body, Instant createdAt) {

        static MessageView of(MessageRecord record) {
            return new MessageView(record.eventId(), record.author(), record.seq(),
                    record.body(), record.createdAt());
        }
    }

    public record CaseView(String caseId, String status, List<MessageView> messages) {

        static CaseView of(CaseRecord record) {
            return new CaseView(record.caseId(), record.status(),
                    record.sortedMessages().stream().map(MessageView::of).toList());
        }
    }
}
