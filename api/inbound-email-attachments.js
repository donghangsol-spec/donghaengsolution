import crypto from "node:crypto";
const MAX=20*1024*1024;
const TYPES=new Map([
 ["application/pdf","pdf"],["image/png","png"],["image/jpeg","jpg"],
 ["application/vnd.ms-excel","xls"],
 ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet","xlsx"],
 ["text/csv","csv"]
]);
function cleanName(x){return String(x||"attachment").replace(/[^a-zA-Z0-9._-]/g,"_").slice(-120);}
async function sb(path,opts={}){const base=process.env.SUPABASE_URL,key=process.env.SUPABASE_SERVICE_ROLE_KEY;if(!base||!key)throw new Error("server config missing");const r=await fetch(base+path,{...opts,headers:{apikey:key,Authorization:`Bearer ${key}`,...(opts.headers||{})}});if(!r.ok)throw new Error("supabase request failed");return r.status===204?null:r.json();}
export async function ingestAttachment({organizationId,messageId,url,filename,mimeType,declaredSize}){
 const ext=TYPES.get(String(mimeType||"").toLowerCase()); if(!ext)throw new Error("unsupported mime");
 if(Number(declaredSize)>MAX)throw new Error("attachment too large");
 const response=await fetch(url,{redirect:"error"}); if(!response.ok)throw new Error("attachment fetch failed");
 const actualType=String(response.headers.get("content-type")||"").split(";")[0].toLowerCase();
 if(actualType!==String(mimeType||"").toLowerCase()||!TYPES.has(actualType))throw new Error("mime mismatch");
 const len=Number(response.headers.get("content-length")||0); if(len>MAX)throw new Error("attachment too large");
 const bytes=Buffer.from(await response.arrayBuffer()); if(!bytes.length||bytes.length>MAX)throw new Error("invalid attachment size");
 const sha=crypto.createHash("sha256").update(bytes).digest("hex");
 const duplicate=await sb(`/rest/v1/email_intake_attachments?organization_id=eq.${organizationId}&sha256=eq.${sha}&select=id&limit=1`);
 if(duplicate?.length)return {duplicate:true,id:duplicate[0].id};
 const safe=cleanName(filename); const path=`${organizationId}/${messageId}/${sha}.${ext}`;
 await sb(`/storage/v1/object/email-intake-private/${path}`,{method:"POST",headers:{"Content-Type":actualType,"x-upsert":"false"},body:bytes});
 try{
  const rows=await sb("/rest/v1/email_intake_attachments",{method:"POST",headers:{"Content-Type":"application/json",Prefer:"return=representation"},body:JSON.stringify({message_id:messageId,organization_id:organizationId,original_filename:safe,mime_type:actualType,byte_size:bytes.length,sha256:sha,storage_path:path,processing_status:"received"})});
  const id=rows?.[0]?.id;\n  if(id)await sb("/rest/v1/rpc/create_intake_classification_draft",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({p_attachment_id:id,p_organization_id:organizationId,p_filename:safe,p_mime_type:actualType})});\n  return {duplicate:false,id,sha256:sha};
 }catch(e){
  await sb(`/storage/v1/object/email-intake-private/${path}`,{method:"DELETE"});
  throw e;
 }
}
