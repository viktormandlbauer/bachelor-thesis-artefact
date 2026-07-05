package at.thesis.poc.management.messaging;

/** AMQP publish did not complete; the REST layer maps this to 503 (plan §3.3). */
public class PublishFailedException extends RuntimeException {

    public PublishFailedException(String message, Throwable cause) {
        super(message, cause);
    }
}
