package at.thesis.poc.submission.messaging;

/** AMQP publish did not complete; the REST layer maps this to 503 (plan §3.1). */
public class PublishFailedException extends RuntimeException {

    public PublishFailedException(String message, Throwable cause) {
        super(message, cause);
    }
}
