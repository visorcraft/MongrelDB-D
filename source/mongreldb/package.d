// mongreldb — public package root for the MongrelDB D client.
//
// Re-exports the main client, transaction, and query builder modules. Import
// the whole client surface with:
//
// ---
// import mongreldb;
// ---

module mongreldb;

public import mongreldb.client;
public import mongreldb.transaction;
public import mongreldb.query;
