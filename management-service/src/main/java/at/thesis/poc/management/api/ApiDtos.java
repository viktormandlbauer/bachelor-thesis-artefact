package at.thesis.poc.management.api;

import java.time.Instant;
import java.util.List;

import at.thesis.poc.management.domain.CaseService.CaseSummaryData;
import at.thesis.poc.management.domain.CaseService.CaseThread;
import at.thesis.poc.management.domain.MessageEntity;

/** Request/response payloads of the management API (plan §5.2). */
public final class ApiDtos {

    private ApiDtos() {
    }

    public record MessageRequest(String message) {
    }

    public record ReplyResponse(String caseId, String eventId, String status) {
    }

    public record CaseSummary(String caseId, String status, long messageCount,
                              Instant createdAt, Instant updatedAt) {

        static CaseSummary of(CaseSummaryData data) {
            return new CaseSummary(data.caseEntity().caseId.toString(), data.caseEntity().status,
                    data.messageCount(), data.caseEntity().createdAt, data.caseEntity().updatedAt);
        }
    }

    public record MessageView(String eventId, String author, long seq, String body, Instant createdAt) {

        static MessageView of(MessageEntity message) {
            return new MessageView(message.eventId.toString(), message.author, message.seq,
                    message.body, message.createdAt);
        }
    }

    public record CaseView(String caseId, String status, List<MessageView> messages) {

        static CaseView of(CaseThread thread) {
            return new CaseView(thread.caseEntity().caseId.toString(), thread.caseEntity().status,
                    thread.messages().stream().map(MessageView::of).toList());
        }
    }
}
