// The underlying HTTP transport (shared across every http:Client and
// http:Listener in the runtime) keeps non-daemon threads alive well
// beyond any individual listener's stop() call -- confirmed empirically
// this session: even a single listener, explicitly immediateStop()'d,
// left this process running for minutes past main() returning. A plain
// http:Client-only program (no listener at all) exits on its own
// immediately, which isolates the cause to the listener's own transport
// threads specifically, not the client's.
//
// This is a real, well-known Ballerina/JVM characteristic for a one-shot
// script -- not a bug in this demo or in ballerina/a2a -- and the
// accepted way to end a program past it is an explicit process exit via
// Java interop. A long-running service (like the server package in this
// same demo) never needs this: it's supposed to keep running until an
// operator stops it.

import ballerina/jballerina.java;

isolated function exitProcess(int status) = @java:Method {
    'class: "java.lang.System",
    name: "exit"
} external;
