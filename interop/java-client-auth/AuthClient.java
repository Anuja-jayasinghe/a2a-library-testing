import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.function.BiConsumer;
import java.util.function.Consumer;

import org.a2aproject.sdk.A2A;
import org.a2aproject.sdk.client.Client;
import org.a2aproject.sdk.client.ClientEvent;
import org.a2aproject.sdk.client.TaskEvent;
import org.a2aproject.sdk.client.TaskUpdateEvent;
import org.a2aproject.sdk.client.http.A2ACardResolver;
import org.a2aproject.sdk.client.transport.rest.RestTransport;
import org.a2aproject.sdk.client.transport.rest.RestTransportConfigBuilder;
import org.a2aproject.sdk.client.transport.spi.interceptors.auth.AuthInterceptor;
import org.a2aproject.sdk.client.transport.spi.interceptors.auth.CredentialService;
import org.a2aproject.sdk.spec.AgentCard;

/**
 * X-A2 (INTEROP_AND_AUTH_TEST_PLAN.md): the real a2a-java client, using its own
 * AuthInterceptor + CredentialService, against ballerina/a2a's Listener with
 * `auth` configured. Usage: AuthClient <baseUrl> [token]. With no token the
 * CredentialService returns null, i.e. "no credential in the store".
 *
 * Success is "received a Task event". The reference client has a known,
 * separate problem -- it throws "Stream 1 cancelled" after a streaming send
 * completes (interop/RESULTS.md finding 6) -- so an error *after* a TaskEvent is
 * not counted against the listener.
 */
public class AuthClient {
    public static void main(String[] args) throws Exception {
        String baseUrl = args[0];
        String token = args.length > 1 && !args[1].isEmpty() ? args[1] : null;

        AgentCard card = A2ACardResolver.builder().baseUrl(baseUrl).build().getAgentCard();
        System.out.println("card securitySchemes: " + card.securitySchemes().keySet());

        CredentialService creds = (schemeName, ctx) -> token;   // same token for whichever scheme the card names
        CompletableFuture<String> outcome = new CompletableFuture<>();
        BiConsumer<ClientEvent, AgentCard> consumer = (event, c) -> {
            if (event instanceof TaskEvent || event instanceof TaskUpdateEvent) {
                outcome.complete("AUTH_OK");
            }
        };
        Consumer<Throwable> onError = t -> outcome.complete("AUTH_REJECTED: " + t.getMessage());

        Client client = Client.builder(card)
                .addConsumers(List.of(consumer))
                .streamingErrorHandler(onError)
                .withTransport(RestTransport.class,
                        new RestTransportConfigBuilder().addInterceptor(new AuthInterceptor(creds)).build())
                .build();
        try {
            client.sendMessage(A2A.toUserMessage("hello from the Java client"));
        } catch (Exception e) {
            outcome.complete("AUTH_REJECTED: " + e.getMessage());
        }
        System.out.println(outcome.get(20, TimeUnit.SECONDS));
        System.exit(0);
    }
}
