/// A TDS session that can ask the server to reset the connection state, as
/// ADO.NET does when reusing a pooled connection.
///
/// On the next request sent (SQL batch or RPC), implementations must set the
/// RESETCONNECTION bit (`0x08`) in the status field of the first packet's
/// header and then clear the pending request. The server runs the
/// equivalent of `sp_reset_connection` before the command: it rolls back
/// transactions, drops temporary tables, closes cursors, restores the
/// database and SET options to their login state, ends `EXECUTE AS` and
/// clears `CONTEXT_INFO`/`SESSION_CONTEXT`. The response carries an
/// ENVCHANGE `TDS_ENV_RESET_COMPLETION_ACK` (18).
///
/// `MssqlPool` uses this interface, when the session implements it, to clean
/// up connections whose state the user changed; without it, those
/// connections are discarded.
abstract interface class ResettableSession {
  /// Marks the next request to be sent with RESETCONNECTION.
  void resetConnectionOnNextRequest();
}
