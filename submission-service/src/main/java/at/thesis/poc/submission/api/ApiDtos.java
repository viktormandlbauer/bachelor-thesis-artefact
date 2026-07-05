package at.thesis.poc.submission.api;

import java.time.Instant;
import java.util.List;

import at.thesis.poc.submission.domain.CaseRecord;
import at.thesis.poc.submission.domain.MessageRecord;

/** Request/response payloads of the submission API (plan §4.1). */
public final class ApiDtos {

    private ApiDtos() {
    }

    public record MessageRequest(String message) {
    }

    public record CreateCaseResponse(String caseId, String eventId, String accessToken, String note) {
    }

    public record AppendMessageResponse(String caseId, String eventId, String status) {
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
