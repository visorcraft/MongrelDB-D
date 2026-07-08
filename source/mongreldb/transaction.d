// mongreldb.transaction — staging buffer for atomic batch commits.
//
// A Transaction stages operations locally and commits them atomically in a
// single /kit/txn request. The engine enforces unique, foreign-key, check, and
// trigger constraints at commit time; on any violation all operations roll
// back and Commit throws a ConflictException carrying the server's structured
// error code and offending op index.
//
// A Transaction is single-use: after commit() or rollback() it must not be
// reused. Calling commit() or rollback() a second time throws an Exception.

module mongreldb.transaction;

import mongreldb.client;

import std.json : JSONValue;

///
/// Thrown when commit() or rollback() is called on a transaction that has
/// already been committed or rolled back.
enum alreadyCommittedMsg = "mongreldb: transaction already committed";

///
/// Stages operations locally and commits them atomically.
class Transaction
{
    private MongrelDBClient _client;
    private JSONValue[] _ops;
    private bool _committed;

    ///
    /// Construct a transaction bound to `client`. Use `MongrelDBClient.begin()`
    /// instead of constructing one directly.
    this(MongrelDBClient client)
    {
        _client = client;
    }

    ///
    /// Stage an insert. `returning`, when `true`, asks the daemon to echo the
    /// row in the per-operation result. Returns `this` for chaining.
    Transaction put(string table, Cell[] cells, bool returning = false)
    {
        auto op = JSONValue([JSONValue()]);
        op.object = null;
        auto putOp = JSONValue([JSONValue()]);
        putOp.object = null;
        putOp["table"] = JSONValue(table);
        putOp["cells"] = JSONValue(flattenCells(cells));
        putOp["returning"] = JSONValue(returning);
        op["put"] = putOp;
        _ops ~= op;
        return this;
    }

    ///
    /// Stage a delete by the internal row id. Returns `this` for chaining.
    Transaction delete(string table, long rowId)
    {
        auto op = JSONValue([JSONValue()]);
        op.object = null;
        auto del = JSONValue([JSONValue()]);
        del.object = null;
        del["table"] = JSONValue(table);
        del["row_id"] = JSONValue(rowId);
        op["delete"] = del;
        _ops ~= op;
        return this;
    }

    ///
    /// Stage a delete by primary-key value. Returns `this` for chaining.
    Transaction deleteByPk(string table, JSONValue pk)
    {
        auto op = JSONValue([JSONValue()]);
        op.object = null;
        auto del = JSONValue([JSONValue()]);
        del.object = null;
        del["table"] = JSONValue(table);
        del["pk"] = pk;
        op["delete_by_pk"] = del;
        _ops ~= op;
        return this;
    }

    ///
    /// The number of staged operations.
    @property long count() const pure nothrow
    {
        return cast(long) _ops.length;
    }

    ///
    /// Send all staged operations atomically and return the per-operation
    /// results. `idempotencyKey`, when non-empty, makes the commit safe to
    /// retry — the daemon returns the original response on duplicate commits,
    /// even after a crash.
    ///
    /// Throws: `Exception` if called twice on the same transaction;
    ///     `ConflictException` if a constraint violation rolled back the batch.
    JSONValue[] commit(string idempotencyKey = null)
    {
        if (_committed)
        {
            throw new Exception(alreadyCommittedMsg);
        }
        _committed = true;
        if (_ops.length == 0)
        {
            return [];
        }
        return _client.commitTxn(_ops, idempotencyKey);
    }

    ///
    /// Discard all staged operations. Throws `Exception` if the transaction
    /// was already committed.
    void rollback()
    {
        if (_committed)
        {
            throw new Exception(alreadyCommittedMsg);
        }
        _ops = [];
        _committed = true;
    }
}
