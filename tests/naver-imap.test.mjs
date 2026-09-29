import assert from 'node:assert/strict';
import { collectNaver, classifyNaverMessage, naverConfigured, pendingNaverUids } from '../api/naver-imap.js';

const settings = { user:'donghangsol@naver.com', password:'synthetic', organizationId:'00000000-0000-4000-8000-000000000001', dbUrl:'https://example.invalid', dbKey:'synthetic' };
assert.equal(naverConfigured(settings), true);
assert.equal(classifyNaverMessage({envelope:{from:[{address:'unknown@example.com'}],subject:'급여대장'}})?.sender,'unknown@example.com');
assert.equal(classifyNaverMessage({envelope:{from:[{address:'approved@example.com'}],subject:'안녕하세요'},bodyStructure:{childNodes:[{dispositionParameters:{filename:'거래내역.xls'}}]}},settings)?.classification,'transaction');
const allUids = Array.from({length: 25}, (_, index) => index + 1);
const first = pendingNaverUids(allUids, new Set(), settings.organizationId, 123);
assert.deepEqual(first.uids, allUids.slice(-20));
assert.equal(first.hasMore, true);
const completed = new Set(first.uids.map(uid => `naver:${settings.organizationId}:123:${uid}`));
const second = pendingNaverUids(allUids, completed, settings.organizationId, 123);
assert.deepEqual(second.uids, allUids.slice(0, 5));
assert.equal(second.hasMore, false);
const posted=[];
class FakeClient {
  mailbox={uidValidity:123};
  async connect() {}
  async getMailboxLock() { return {release(){}}; }
  async search(){return [1,2];}
  async fetchOne(uid, query){if(query.source)return {source:Buffer.from('From: approved@example.com\r\nSubject: 급여대장\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n테스트')};return {uid, size:1024, internalDate:new Date('2026-09-28T00:00:00Z'),envelope:{from:[{address:uid===1?'approved@example.com':'untrusted@example.com'}],subject:'급여대장'}};}
  async logout(){}
}
const result=await collectNaver(settings,{Client:FakeClient,request:async (url, options)=>{if(options.body){posted.push(JSON.parse(options.body));return {ok:true}}if(url.includes('select=provider_message_id')||url.includes('email_content_drafts'))return {ok:true,json:async()=>[]};return {ok:true,json:async()=>[{id:'00000000-0000-4000-8000-000000000002'}]};}});
assert.deepEqual({checked:result.checked,reviewed:result.reviewed,ignored:result.ignored},{checked:2,reviewed:2,ignored:0});
assert.equal(posted[0].provider_message_id,`naver:${settings.organizationId}:123:1`);
assert.equal(posted[0].processing_status,'review_required');
assert.equal(posted[1].text_preview,'테스트');
assert.equal(posted[2].sender,'untrusted@example.com');
assert.equal(posted[2].processing_status,'review_required');
console.log('Naver IMAP collector checks passed');
