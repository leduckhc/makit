/**
 * Canonical UICall schema — vendor-neutral language between agents and makit app.
 *
 * Agent connectors (server/connectors/*.ts) translate native tool params into
 * one of these variants, POST to the loopback HTTP bridge, and receive the
 * user's choice. The app has a single dispatcher (SrvRequestHandler) that
 * renders the appropriate UI for each `kind`.
 *
 * To add a new UI interaction:
 *   1. Add a variant to the UICall union here (e.g., ConfirmAction, EditFile).
 *   2. Add a renderer in app/lib/ui/widgets/srv_request_handler.dart.
 *   3. Both can evolve independently as long as the TSM stays stable.
 *
 * Why union not enum: the payload is different for each kind. pi's
 * askUserQuestion looks nothing like claude's tool_use_block preview, etc.
 */
export {};
//# sourceMappingURL=uicall.js.map