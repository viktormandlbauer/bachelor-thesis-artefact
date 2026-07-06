package at.thesis.poc.submission.api;

import java.time.Instant;
import java.util.List;

import at.thesis.poc.submission.domain.CaseService.CaseThread;
import at.thesis.poc.submission.domain.MessageEntity;

/** Request/response payloads of the submission API (plan §5.1). */
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
