/-
Copyright (c) 2020 Marc Huisinga. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.

Authors: Marc Huisinga, Wojciech Nawrocki
-/
import Init.Control
import Init.System.IO
import Std.Data.RBTree
import Lean.Data.Json

/-! Implementation of JSON-RPC 2.0 (https://www.jsonrpc.org/specification)
for use in the LSP server. -/

namespace Lean
namespace JsonRpc

open Json
open Std (RBNode)

inductive RequestID where
  | str (s : String)
  | num (n : JsonNumber)
  | null

/-- Error codes defined by JSON-RPC and LSP. -/
inductive ErrorCode where
  | parseError
  | invalidRequest
  | methodNotFound
  | invalidParams
  | internalError
  | serverErrorStart
  | serverErrorEnd
  | serverNotInitialized
  | unknownErrorCode
  -- LSP-specific codes below.
  | requestCancelled
  | contentModified

instance : FromJson ErrorCode := ⟨fun
  | num (-32700 : Int) => ErrorCode.parseError
  | num (-32600 : Int) => ErrorCode.invalidRequest
  | num (-32601 : Int) => ErrorCode.methodNotFound
  | num (-32602 : Int) => ErrorCode.invalidParams
  | num (-32603 : Int) => ErrorCode.internalError
  | num (-32099 : Int) => ErrorCode.serverErrorStart
  | num (-32000 : Int) => ErrorCode.serverErrorEnd
  | num (-32002 : Int) => ErrorCode.serverNotInitialized
  | num (-32001 : Int) => ErrorCode.unknownErrorCode
  | num (-32800 : Int) => ErrorCode.requestCancelled
  | num (-32801 : Int) => ErrorCode.contentModified
  | _  => none⟩

instance : ToJson ErrorCode := ⟨fun
  | ErrorCode.parseError           => (-32700 : Int)
  | ErrorCode.invalidRequest       => (-32600 : Int)
  | ErrorCode.methodNotFound       => (-32601 : Int)
  | ErrorCode.invalidParams        => (-32602 : Int)
  | ErrorCode.internalError        => (-32603 : Int)
  | ErrorCode.serverErrorStart     => (-32099 : Int)
  | ErrorCode.serverErrorEnd       => (-32000 : Int)
  | ErrorCode.serverNotInitialized => (-32002 : Int)
  | ErrorCode.unknownErrorCode     => (-32001 : Int)
  | ErrorCode.requestCancelled     => (-32800 : Int)
  | ErrorCode.contentModified      => (-32801 : Int)⟩

/- Uses separate constructors for notifications and errors because client and server
behavior is expected to be wildly different for both. -/
inductive Message where
  | request (id : RequestID) (method : String) (params? : Option Structured)
  | notification (method : String) (params? : Option Structured)
  | response (id : RequestID) (result : Json)
  | responseError (id : RequestID) (code : ErrorCode) (message : String) (data? : Option Json)

def Batch := Array Message

-- Compound type with simplified APIs for passing around
-- jsonrpc data
structure Request (α) where
  id     : RequestID
  method : String
  param  : α

instance [ToJson α] : Coe (Request α) Message :=
⟨fun r => Message.request r.id r.method (toStructured? r.param)⟩

structure Notification (α) where
  method : String
  param  : α

instance [ToJson α] : Coe (Notification α) Message :=
⟨fun r => Message.notification r.method (toStructured? r.param)⟩

structure Response (α) where
  id     : RequestID
  result : α

instance [ToJson α] : Coe (Response α) Message :=
⟨fun r => Message.response r.id (toJson r.result)⟩

structure ResponseError (α) where
  id      : RequestID
  code    : ErrorCode
  message : String
  data?   : Option α := none

instance [ToJson α] : Coe (ResponseError α) Message :=
⟨fun r => Message.responseError r.id r.code r.message (r.data?.map toJson)⟩

instance : Coe String RequestID := ⟨RequestID.str⟩
instance : Coe JsonNumber RequestID := ⟨RequestID.num⟩

private def RequestID.lt : RequestID → RequestID → Bool
  | RequestID.str a, RequestID.str b            => a < b
  | RequestID.num a, RequestID.num b            => a < b
  | RequestID.null,  RequestID.num _            => true
  | RequestID.null,  RequestID.str _            => true
  | RequestID.num _, RequestID.str _            => true
  | _, _ /- str < *, num < null, null < null -/ => false

private def RequestID.ltProp : HasLess RequestID :=
  ⟨fun a b => RequestID.lt a b = true⟩

instance : HasLess RequestID :=
  RequestID.ltProp

instance (a b : RequestID) : Decidable (a < b) :=
  inferInstanceAs (Decidable (RequestID.lt a b = true))

instance : FromJson RequestID := ⟨fun j =>
  match j with
  | str s => RequestID.str s
  | num n => RequestID.num n
  | _     => none⟩

instance : ToJson RequestID := ⟨fun rid =>
  match rid with
  | RequestID.str s => s
  | RequestID.num n => num n
  | RequestID.null  => null⟩

instance : ToJson Message := ⟨fun m =>
  mkObj $ ⟨"jsonrpc", "2.0"⟩ :: match m with
  | Message.request id method params? =>
    [ ⟨"id", toJson id⟩,
      ⟨"method", method⟩
    ] ++ opt "params" params?
  | Message.notification method params? =>
    ⟨"method", method⟩ ::
    opt "params" params?
  | Message.response id result =>
    [ ⟨"id", toJson id⟩,
      ⟨"result", result⟩]
  | Message.responseError id code message data? =>
    [ ⟨"id", toJson id⟩,
      ⟨"error", mkObj $ [
          ⟨"code", toJson code⟩,
          ⟨"message", message⟩
        ] ++ opt "data" data?⟩
    ]⟩

instance : FromJson Message := ⟨fun j => do
  let "2.0" ← j.getObjVal? "jsonrpc" | none
  (do let id ← j.getObjValAs? RequestID "id"
      let method ← j.getObjValAs? String "method"
      let params? := j.getObjValAs? Structured "params"
      pure (Message.request id method params?)) <|>
  (do let method ← j.getObjValAs? String "method"
      let params? := j.getObjValAs? Structured "params"
      pure (Message.notification method params?)) <|>
  (do let id ← j.getObjValAs? RequestID "id"
      let result ← j.getObjVal? "result"
      pure (Message.response id result)) <|>
  (do let id ← j.getObjValAs? RequestID "id"
      let err ← j.getObjVal? "error"
      let code ← err.getObjValAs? ErrorCode "code"
      let message ← err.getObjValAs? String "message"
      let data? := err.getObjVal? "data"
      pure (Message.responseError id code message data?))⟩

end JsonRpc
end Lean

namespace IO.FS.Stream

open Lean
open Lean.JsonRpc

section
  variables (h : FS.Stream) (nBytes : Nat) (expectedMethod : String) (α) [FromJson α]

  def readMessage : IO Message := do
    let j ← h.readJson nBytes
    match fromJson? j with
    | some m => pure m
    | none   => throw $ userError ("JSON '" ++ j.compress ++ "' did not have the format of a JSON-RPC message")

  def readRequestAs : IO (Request α) := do
    let m ← h.readMessage nBytes
    match m with
    | Message.request id method params? =>
      if method = expectedMethod then
        match params? with
        | some params =>
          let j := toJson params
          match fromJson? j with
          | some v => pure ⟨id, expectedMethod, v⟩
          | none   => throw $ userError ("unexpected param '" ++ j.compress  ++ "' for method '" ++ expectedMethod ++ "'")
        | none => throw $ userError ("unexpected lack of param for method '" ++ expectedMethod ++ "'")
      else
        throw $ userError ("expected method '" ++ expectedMethod ++ "', got method '" ++ method ++ "'")
    | _ => throw $ userError "expected request, got other type of message"

  def readNotificationAs : IO (Notification α) := do
    let m ← h.readMessage nBytes
    match m with
    | Message.notification method params? =>
      if method = expectedMethod then
        match params? with
        | some params =>
          let j := toJson params
          match fromJson? j with
          | some v => pure ⟨expectedMethod, v⟩
          | none   => throw $ userError ("unexpected param '" ++ j.compress  ++ "' for method '" ++ expectedMethod ++ "'")
        | none => throw $ userError ("unexpected lack of param for method '" ++ expectedMethod ++ "'")
      else
        throw $ userError ("expected method '" ++ expectedMethod ++ "', got method '" ++ method ++ "'")
    | _ => throw $ userError "expected notification, got other type of message"
end

section
  variables [ToJson α] (h : FS.Stream)

  def writeMessage (m : Message) : IO Unit :=
    h.writeJson (toJson m)

  def writeRequest (r : Request α) : IO Unit :=
    h.writeMessage r

  def writeNotification (n : Notification α) : IO Unit :=
    h.writeMessage n

  def writeResponse (r : Response α) : IO Unit :=
    h.writeMessage r

  def writeResponseError (e : ResponseError Unit) : IO Unit :=
    h.writeMessage (Message.responseError e.id e.code e.message none)

  def writeResponseErrorWithData (e : ResponseError α) : IO Unit :=
    h.writeMessage e
end

end IO.FS.Stream
