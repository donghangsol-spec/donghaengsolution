import assert from 'node:assert/strict';
import { collectNaver, classifyNaverMessage, naverConfigured } from '../api/naver-imap.js';

const settings = { user:'donghangsol@naver.com', password:'synthetic', organizationId:'00000000-0000-4000-8000-000000000001', dbUrl:'https://example.invalid', dbKey:'synthetic', senders:['approved@example.com'] };
assert.equal(naverConfigured(settings), true);
assert.equal(classifyNaverMessage({envelope:{from:[{address:'unknown@example.com'}],subject:'급여대장'}},settings),null);
assert.equal(classifyNaverMessage({envelope:{from:[{address:'approved@example.com'}],subject:'안녕하세요'},bodyStructure:{childNodes:[{dispositionParameters:{filename:'거래내역.xls'}}]}},settings)?.classification,'transaction');
const posted=[];
class FakeClient {
  mailbox={uidValidity:123};
  async connect() {}
  async getMailboxLock() { return {release(){}}; }
  async search(){return [1,2];}
  async fetchOne(uid){return {uid, internalDate:new Date('2026-09-28T00:00:00Z'),envelope:{from:[{address:uid===1?'approved@example.com':'untrusted@example.com'}],subject:'급여대장'}};}
  async logout(){}
}
const result=await collectNaver(settings,{Client:FakeClient,request:async (url, options)=>{posted.push(JSON.parse(options.body));return {ok:true};}});
assert.deepEqual({checked:result.checked,reviewed:result.reviewed,ignored:result.ignored},{checked:2,reviewed:1,ignored:1});
assert.equal(posted[0].provider_message_id,`naver:${settings.organizationId}:123:1`);
assert.equal(posted[0].processing_status,'review_required');
console.log('Naver IMAP collector checks passed');
