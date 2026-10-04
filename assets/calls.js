import { initContactList } from "./contacts.js";

initContactList({
  navKey: "calls",
  rpcSources: "list_call_sources",
  rpcSearch: "search_calls",
  rpcCount: "count_calls",
  emptyHint: "No cold calling numbers yet — upload some from the Cold calling page of the uploader (./run_upload.sh).",
  emptyList: "No cold calling numbers loaded yet."
});
