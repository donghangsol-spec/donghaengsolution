import crypto from "node:crypto";
const MAX=20*1024*1024;
const TYPES=new Map([
 ["application/pdf","pdf"],["image/png","png"],["image/jpeg","jpg"],
 ["application/vnd.ms-excel","xls"],["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet","xlsx"],["text/csv","csv"]
]);
const ALLOWED_HOSTS=new Set(["resend.com","api.resend.com"]);
function cleanName(x){return String(x||"attachment").replace(/[^a-zA-Z0-9._-]/g,"_").slice(-120);}
function trustedUrl(raw){let u;try{u=new URL(raw);}catch{throw new Error("invalid attachment url");}if(u.protocol!=="https:")throw new Error("invalid attachment url");const h=u.hostname.toLowerCase();if(![...ALLOWED_HOSTS].some(x=>h===x||h.endsWith("."+x)))throw new Error("untrusted attachment host");if(u.username||u.password)throw new Error("invalid attachment url");return u.toString();}
async function limitedBytes(response){if(!response.body)throw new Error("empty attachment body");const chunks=[];let total=0;for await(const chunk of response.body){const b=Buffer.from(chunk);total+=b.length;if(total>MAX){try{await response.body.cancel();}catch{}throw new Error("attachment too large");}chunks.push(b);}if(!total)throw new Error("invalid attachment size");return Buffer.concat(chunks,total);}
async function sb(path,opts={}){const base=process.env.SUPABASE_URL,key=process.env.SUPABASE_SERVICE_ROLE_KEY;if(!base||!key)throw new Error("server config missing");const r=await fetch(base+path,{...opts,headers:{apikey:key,Authorization:`Bearer ${key}`,...(opts.headers||{})}});if(!r.ok)throw new Error("supabase request failed");return r.status===204?null:r.json();}
export async function ingestAttachment({organizationId,messageId,url,filename,mimeType,declaredSize}){
 const declared=String(mimeType||"").toLowerCase(),ext=TYPES.get(declared);if(!ext)throw new Error("unsupported mime");
 const expectedExt=String(filename||"").split(".").pop().toLowerCase();if(!expectedExt||expectedExt!==ext)throw new Error("extension mismatch");
 if(Number(declaredSize)>MAX)throw new Error("attachment too large");
 const response=await fetch(trustedUrl(url),{redirect:"error",headers:{"Accept":declared}});if(!response.ok)throw new Error("attachment fetch failed");
 const actual=String(response.headers.get("content-type")||"").split(";")[0].toLowerCase();if(actual!==declared||!TYPES.has(actual))throw new Error("mime mismatch");
 const len=Number(response.headers.get("content-length")||0);if(len>MAX)throw new Error("attachment too large");
 const bytes=await limitedBytes(response);const sha=crypto.createHash("sha256").update(bytes).digest("hex");
 const duplicate=await sb(`/rest/v1/email_intake_attachments?organization_id=eq.${organizationId}&sha256=eq.${sha}&select=id&limit=1`);if(duplicate?.length)return {duplicate:true,id:duplicate[0].id};
 const safe=cleanName(filename),path=`${organizationId}/${messageId}/${sha}.${ext}`;
 await sb(`/storage/v1/object/email-intake-private/${path}`,{method:"POST",headers:{"Content-Type":actual,"x-upsert":"false"},body:bytes});
 try{
  const id=await sb("/rest/v1/rpc/ingest_email_attachment_metadata",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({p_message_id:messageId,p_organization_id:organizationId,p_original_filename:safe,p_mime_type:actual,p_byte_size:bytes.length,p_sha256:sha,p_storage_path:path})});
  if(id)await sb("/rest/v1/rpc/create_intake_classification_draft",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({p_attachment_id:id,p_organization_id:organizationId,p_filename:safe,p_mime_type:actual})});
  return {duplicate:false,id,sha256:sha};
 }catch(e){await sb(`/storage/v1/object/email-intake-private/${path}`,{method:"DELETE"});throw e;}
}
