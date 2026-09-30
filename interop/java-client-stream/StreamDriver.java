// Real a2a-java client -> ballerina/a2a Listener, streaming send. Unlike the helloworld sample (which only
// completes its future on a Message reply and so hangs against a task-producing agent), this driver counts
// events and error callbacks for a grace period after the last event, to catch a spurious terminal callback
// (RESULTS.md finding 6). Per upstream #1173 the handler gets exactly one terminal signal: null = normal completion.
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import org.a2aproject.sdk.A2A;
import org.a2aproject.sdk.client.*;
import org.a2aproject.sdk.client.http.A2ACardResolver;
import org.a2aproject.sdk.client.transport.rest.*;
import org.a2aproject.sdk.spec.AgentCard;

public class StreamDriver {
    public static void main(String[] a) throws Exception {
        String url = a.length > 0 ? a[0] : "http://localhost:9999";
        AgentCard card = A2ACardResolver.builder().baseUrl(url).build().getAgentCard();
        AtomicInteger events = new AtomicInteger(), errors = new AtomicInteger(), completions = new AtomicInteger();
        StringBuilder kinds = new StringBuilder();
        Client c = Client.builder(card)
            .addConsumers(List.of((ev, ac) -> { events.incrementAndGet(); kinds.append(ev.getClass().getSimpleName()).append(' '); }))
            .streamingErrorHandler(t -> { if (t == null) completions.incrementAndGet(); else { errors.incrementAndGet(); System.out.println("ERROR CALLBACK: " + t); } })
            .withTransport(RestTransport.class, new RestTransportConfig()).build();
        c.sendMessage(A2A.toUserMessage("how much is 10 USD in INR?"));
        Thread.sleep(8000);
        System.out.println("events=" + events + " [" + kinds.toString().trim() + "] errors=" + errors + " normalCompletions=" + completions);
        System.out.println(events.get() >= 2 && errors.get() == 0 && completions.get() == 1 ? "PASS" : "FAIL");
        System.exit(0);
    }
}
