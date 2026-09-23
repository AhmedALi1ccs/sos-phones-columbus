import { initContactList } from "./contacts.js";

initContactList({
  navKey: "sms",
  rpcSources: "list_sms_sources",
  rpcSearch: "search_sms",
  rpcCount: "count_sms",
  emptyHint: "No SMS numbers yet — upload some from the SMS page of the uploader.",
  emptyList: "No SMS numbers loaded yet."
});
