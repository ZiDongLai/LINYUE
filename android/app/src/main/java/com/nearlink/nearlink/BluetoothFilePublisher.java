package com.nearlink.nearlink;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.security.MessageDigest;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/** FIX1 transaction core. No Android, network, links, copy fallback or trust code.
 * Android supplies same-device stat, rename(2) and directory fsync operations.
 * Target names are local random names in a private namespace, never peer paths.
 */
public final class BluetoothFilePublisher {
    public interface Operations {
        boolean sameFileSystem(File source, File directory) throws Exception;
        String identity(File file) throws Exception;
        void rename(File source, File target) throws Exception;
        void syncDirectory(File directory) throws Exception;
        boolean writable(File directory);
    }
    public interface Diagnostics { void event(Map<String, Object> fields); }
    public static final class Failure extends IOException {
        public final Map<String, Object> details;
        public Failure(Map<String, Object> fields, Exception cause) {
            super("Bluetooth file commit failed at " + fields.get("stage"), cause);
            details = new LinkedHashMap<>(fields);
        }
    }
    private static final class Trace {
        final Map<String, Object> fields = new LinkedHashMap<>();
        final Diagnostics sink;
        Trace(Diagnostics sink) { this.sink = sink; fields.put("storageType", "app-private-internal"); }
        void stage(String stage, String operation) {
            fields.put("stage", stage); fields.put("operation", operation); emit();
        }
        void emit() {
            if (sink != null) {
                try { sink.event(new LinkedHashMap<>(fields)); } catch (RuntimeException ignored) { }
            }
        }
    }
    public static String digest(File file) throws Exception {
        MessageDigest hash = MessageDigest.getInstance("SHA-256");
        try (FileInputStream input = new FileInputStream(file)) {
            byte[] buffer = new byte[8192]; int n;
            while ((n = input.read(buffer)) != -1) hash.update(buffer, 0, n);
        }
        StringBuilder out = new StringBuilder();
        for (byte b : hash.digest()) {
            out.append(Character.forDigit((b >>> 4) & 15, 16));
            out.append(Character.forDigit(b & 15, 16));
        }
        return out.toString();
    }
    private static String tag(File file) throws Exception {
        MessageDigest hash = MessageDigest.getInstance("SHA-256");
        byte[] bytes = hash.digest(file.getCanonicalPath().getBytes("UTF-8"));
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < 6; ++i) out.append(String.format("%02x", bytes[i] & 255));
        return out.toString();
    }
    private static void checkName(String name) throws IOException {
        if (name == null || name.isEmpty() || name.length() > 120 || !name.equals(name.trim()) ||
            name.startsWith(".") || name.endsWith(".") || name.endsWith(".part") || name.endsWith(".writing") ||
            name.matches("(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\\..*)?$")) {
            throw new IOException("invalid-filename");
        }
        for (char c : name.toCharArray()) {
            if (c < 32 || "\\/:*?\"<>|".indexOf(c) >= 0) throw new IOException("invalid-filename");
        }
    }
    private static String safeReason(Exception e, File privateRoot) {
        String reason = String.valueOf(e.getMessage());
        if (reason.toLowerCase().contains("permission denied") || reason.contains("EACCES")) return "EACCES (Permission denied)";
        if (reason.toLowerCase().contains("access denied")) return "Access denied";
        if (reason.toLowerCase().contains("no space") || reason.contains("ENOSPC")) return "ENOSPC (No space left)";
        reason = reason.replace(privateRoot.getAbsolutePath(), "<app-private>");
        if (reason.contains("/") || reason.contains("\\")) return "path-bearing message redacted";
        return reason.replaceAll("[\\r\\n\\t]", " ").substring(0, Math.min(reason.length(), 160));
    }
    public static synchronized File publish(File workRoot, File inboxRoot, File sourceFile,
            String name, long size, String expectedSha, Operations ops, Diagnostics sink) throws Failure {
        return publishWithNonce(workRoot, inboxRoot, sourceFile, name, size, expectedSha, ops, sink,
            UUID.randomUUID().toString().replace("-", ""));
    }
    // Package-private deterministic nonce permits collision tests; production always uses local UUID.
    static synchronized File publishWithNonce(File workRoot, File inboxRoot, File sourceFile,
            String name, long size, String expectedSha, Operations ops, Diagnostics sink, String nonce) throws Failure {
        return publishWithNonce(workRoot,inboxRoot,sourceFile,name,size,expectedSha,ops,sink,nonce,false,10485760);
    }
    public static synchronized File publishReserved(File workRoot, File inboxRoot, File sourceFile,
            String name, long size, String expectedSha, Operations ops, Diagnostics sink, String nonce) throws Failure {
        return publishWithNonce(workRoot,inboxRoot,sourceFile,name,size,expectedSha,ops,sink,nonce,true,10485760);
    }
    public static synchronized File publishCandidate(File workRoot, File inboxRoot, File sourceFile,
            String name,long size,String sha,Operations ops,Diagnostics sink,String nonce) throws Failure {
        return publishWithNonce(workRoot,inboxRoot,sourceFile,name,size,sha,ops,sink,nonce,true,10485760);
    }
    private static File publishWithNonce(File workRoot, File inboxRoot, File sourceFile,
            String name, long size, String expectedSha, Operations ops, Diagnostics sink, String nonce, boolean reserved,long maxBytes) throws Failure {
        Trace t = new Trace(sink);
        File source = sourceFile, target = null, work = workRoot, inbox = inboxRoot;
        boolean moved = false; String identity = null;
        t.fields.put("expectedBytes", size);
        try {
            t.stage("validate_source", "canonical-private-path-check");
            work = work.getCanonicalFile(); inbox = inbox.getCanonicalFile(); source = source.getCanonicalFile();
            t.fields.put("sourceTag", "bt-work:" + tag(source));
            t.fields.put("inboxTag", "inbox:" + tag(inbox));
            t.fields.put("sourceExists", source.isFile());
            t.fields.put("sourceReadable", source.canRead());
            t.fields.put("sourceParentWritable", source.getParentFile() != null && ops.writable(source.getParentFile()));
            t.fields.put("sourceBytes", source.length());
            checkName(name);
            if (!work.isDirectory() || !work.getParentFile().equals(inbox.getParentFile()) ||
                source.getParentFile() == null || !work.equals(source.getParentFile().getParentFile()) ||
                !source.getParentFile().getName().startsWith("rx_") || !source.getName().equals("payload.part") ||
                !source.isFile() || !source.canRead() || size < 0 || size > maxBytes || source.length() != size ||
                expectedSha == null || !expectedSha.matches("[a-f0-9]{64}") || !nonce.matches("[a-f0-9]{32}")) {
                throw new IOException("invalid-private-staging-source-or-metadata");
            }
            t.stage("prepare_inbox", "private-directory-preflight");
            t.fields.put("targetDirectoryExisted", inbox.isDirectory());
            if (!inbox.exists() && !inbox.mkdirs() && !inbox.isDirectory()) throw new IOException("target-directory-create-failed");
            t.fields.put("targetDirectoryExists", inbox.isDirectory());
            t.fields.put("targetDirectoryWritable", ops.writable(inbox)); t.emit();
            if (!inbox.isDirectory() || !ops.writable(inbox)) throw new IOException("target-directory-not-writable");
            t.stage("same_filesystem", "stat-device-equality");
            boolean same = ops.sameFileSystem(source, inbox); t.fields.put("sameFilesystem", same); t.emit();
            if (!same) throw new IOException("cross-filesystem-commit-refused");
            t.stage("verify_temporary", "length-and-sha256");
            if (source.length() != size || !digest(source).equals(expectedSha)) throw new IOException("temporary-SHA256-mismatch");
            t.fields.put("temporaryHashVerified", true); t.fields.put("sizeVerified", true); t.emit();
            t.stage("sync_temporary", "file-fd-sync");
            try (FileOutputStream file = new FileOutputStream(source, true)) { file.getFD().sync(); }
            identity = ops.identity(source);
            int dot = name.lastIndexOf('.');
            String stem = dot > 0 ? name.substring(0, dot) : name;
            String ext = dot > 0 ? name.substring(dot) : "";
            for (int i = 0; i < (reserved ? 1 : 1000); ++i) {
                File candidate = new File(inbox, stem + "_BT_" + nonce + (i == 0 ? "" : " (" + i + ")") + ext);
                if (!candidate.exists()) { target = candidate; break; }
            }
            if (target == null) throw new IOException("too-many-name-collisions");
            t.fields.put("targetTag", "inbox-file:" + tag(target));
            t.stage("atomic_rename", "rename-same-filesystem-no-copy-no-link");
            // Private 128-bit random namespace + this lock; never rename onto an existing target.
            if (target.exists()) throw new IOException("target-appeared-before-commit");
            ops.rename(source, target); moved = true;
            t.stage("verify_final", "identity-length-sha256-readback");
            if (!identity.equals(ops.identity(target)) || !target.isFile() || !target.canRead() ||
                target.length() != size || !digest(target).equals(expectedSha)) throw new IOException("final-SHA256-or-identity-mismatch");
            t.fields.put("finalBytes", target.length()); t.fields.put("finalHashVerified", true); t.emit();
            t.stage("sync_inbox", "directory-fsync"); ops.syncDirectory(inbox); t.fields.put("inboxSynced", true);
            t.stage("sync_work", "directory-fsync"); ops.syncDirectory(source.getParentFile()); t.fields.put("workSynced", true);
            t.fields.put("commitResult", "success"); t.stage("complete", "return-verified-file");
            return target;
        } catch (Exception failure) {
            t.fields.put("commitResult", "failed");
            t.fields.put("exceptionType", failure.getClass().getName());
            t.fields.put("errorReason", safeReason(failure, work.getParentFile() == null ? work : work.getParentFile()));
            if (moved && target != null) {
                try {
                    if (target.exists() && identity != null && identity.equals(ops.identity(target)) && !source.exists()) {
                        ops.rename(target, source); t.fields.put("rollback", "returned-to-private-staging");
                    }
                } catch (Exception rollbackFailure) {
                    t.fields.put("rollback", "failed-" + rollbackFailure.getClass().getSimpleName());
                    try {
                        if (target.exists() && identity != null && identity.equals(ops.identity(target))) {
                            File hidden = new File(inbox, ".linyue_part_bt_failed_" + nonce);
                            if (!hidden.exists()) { ops.rename(target, hidden); t.fields.put("rollback", "hidden-owned-quarantine"); }
                        }
                    } catch (Exception ignored) { t.fields.put("rollback", "manual-preservation-required"); }
                }
            }
            t.emit(); throw new Failure(t.fields, failure);
        }
    }
    /** Re-establish durability after an interrupted native result, never rename or copy. */
    public static synchronized File verifyReserved(File inboxRoot, String name, long size, String sha,
            Operations ops, String nonce) throws Exception {
        return verifyLimited(inboxRoot,name,size,sha,ops,nonce,10485760);
    }
    public static synchronized File verifyCandidate(File inboxRoot,String name,long size,String sha,Operations ops,String nonce) throws Exception {
        return verifyLimited(inboxRoot,name,size,sha,ops,nonce,10485760);
    }
    private static File verifyLimited(File inboxRoot,String name,long size,String sha,Operations ops,String nonce,long maxBytes) throws Exception {
        checkName(name);
        if(size<0 || size>maxBytes || sha==null || !sha.matches("[a-f0-9]{64}") ||
            nonce==null || !nonce.matches("[a-f0-9]{32}")) throw new IOException("invalid-completion-metadata");
        File inbox=inboxRoot.getCanonicalFile();int dot=name.lastIndexOf('.');
        String stem=dot>0?name.substring(0,dot):name,ext=dot>0?name.substring(dot):"";
        File file=new File(inbox,stem+"_BT_"+nonce+ext);
        if(!inbox.isDirectory() || !file.getCanonicalFile().equals(file.getAbsoluteFile()) ||
            !file.isFile() || !file.canRead() || file.length()!=size || !digest(file).equals(sha)) throw new IOException("completed-file-verification-failed");
        String identity=ops.identity(file);
        try(FileOutputStream output=new FileOutputStream(file,true)){output.getFD().sync();}
        ops.syncDirectory(inbox);
        if(!identity.equals(ops.identity(file)) || file.length()!=size || !digest(file).equals(sha)) throw new IOException("completed-file-changed");
        return file;
    }
    private BluetoothFilePublisher() { }
}
