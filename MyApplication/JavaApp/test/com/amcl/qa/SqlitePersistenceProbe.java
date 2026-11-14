package com.amcl.qa;

import java.nio.file.*;
import java.sql.*;
import java.util.*;

/**
 * 使用原DH驱动验证真实SQLite JNI/VFS，write和reload必须在两个冷JVM中运行。
 * 只在显式新QA目录创建数据库，不接触现有世界；保留数据库供人工审计和跨进程读回。
 */
public final class SqlitePersistenceProbe {
    private static final byte[] BLOB = new byte[65537];
    private static int checks;
    private static void check(boolean ok, String reason) { checks++; if (!ok) throw new AssertionError(reason); }
    // DH不仅重定位包名，还重定位JDBC协议前缀；必须使用原JDBC类声明的真实协议。
    private static String jdbcPrefix;
    private static Connection open(Path file) throws SQLException { return DriverManager.getConnection(jdbcPrefix + file); }
    private static String scalar(Connection db, String sql) throws SQLException {
        try (Statement s = db.createStatement(); ResultSet result = s.executeQuery(sql)) { check(result.next(), "query returned row"); return result.getString(1); }
    }
    private static void execute(Connection db, String sql) throws SQLException { try (Statement s = db.createStatement()) { s.execute(sql); } }

    /** 每个库经历WAL、事务提交/回滚、二连接互斥和关闭重开；reload不修复、不清理任何数据。 */
    private static void database(Path folder, boolean write) throws Exception {
        Path file = folder.resolve("roundtrip.sqlite");
        if (write) { check(!Files.exists(folder), "fresh QA directory"); Files.createDirectories(folder); }
        else check(Files.isRegularFile(file), "cold reload existing database");
        try (Connection db = open(file)) {
            check("ok".equals(scalar(db, "PRAGMA integrity_check")), "integrity before");
            if (write) {
                check("wal".equalsIgnoreCase(scalar(db, "PRAGMA journal_mode=WAL")), "WAL mode");
                execute(db, "PRAGMA synchronous=FULL");
                execute(db, "CREATE TABLE probe(id INTEGER PRIMARY KEY, text_value TEXT, blob_value BLOB)");
                db.setAutoCommit(false);
                try (PreparedStatement insert = db.prepareStatement("INSERT INTO probe VALUES(?,?,?)")) {
                    insert.setInt(1, 1); insert.setString(2, "冷重载-鸿蒙-🧪"); insert.setBytes(3, BLOB); check(insert.executeUpdate() == 1, "prepared insert");
                }
                db.commit();
                execute(db, "INSERT INTO probe(id,text_value) VALUES(2,'rollback')"); db.rollback(); db.setAutoCommit(true);
                try (Connection second = open(file)) {
                    execute(second, "PRAGMA busy_timeout=0");
                    db.setAutoCommit(false); execute(db, "INSERT INTO probe(id,text_value) VALUES(3,'uncommitted')");
                    check("1".equals(scalar(second, "SELECT count(*) FROM probe")), "WAL reader isolation");
                    boolean busy = false;
                    try { execute(second, "INSERT INTO probe(id) VALUES(4)"); }
                    catch (SQLException expected) { busy = expected.getErrorCode() == 5 || expected.getErrorCode() == 6; }
                    check(busy, "second writer receives SQLITE_BUSY/LOCKED"); db.rollback(); db.setAutoCommit(true);
                }
                execute(db, "PRAGMA wal_checkpoint(TRUNCATE)");
            }
            check("1".equals(scalar(db, "SELECT count(*) FROM probe")), "only committed row persists");
            try (Statement s = db.createStatement(); ResultSet row = s.executeQuery("SELECT text_value,blob_value FROM probe WHERE id=1")) {
                check(row.next() && "冷重载-鸿蒙-🧪".equals(row.getString(1)) && Arrays.equals(BLOB, row.getBytes(2)), "Unicode and BLOB exact roundtrip");
            }
            check("ok".equals(scalar(db, "PRAGMA integrity_check")), "integrity after");
        }
        try (Connection reopened = open(file)) { check("1".equals(scalar(reopened, "SELECT count(*) FROM probe")), "same JVM close and reopen"); }
        System.out.println("AMCL_SQLITE_DATABASE mode=" + (write ? "write" : "reload") + " file=" + file + " bytes=" + Files.size(file) + " passed=true");
    }

    public static void main(String[] args) throws Exception {
        // 正常启动器可能追加真实窗口尺寸；只接受这对已知显示参数，不把它们误判为探针载荷。
        boolean dimensions = args.length == 6 && args[2].equals("--width") && args[3].matches("[1-9][0-9]*")
            && args[4].equals("--height") && args[5].matches("[1-9][0-9]*");
        check((args.length == 2 || dimensions) && (args[0].equals("write") || args[0].equals("reload")), "explicit mode and QA root");
        String temp = System.getProperty("dh_sqlite.tmpdir");
        check(temp != null && temp.equals(System.getenv("TMPDIR")), "automatic private native directory");
        for (int i = 0; i < BLOB.length; i++) BLOB[i] = (byte)(i * 37 + 11);
        Class<?> driver = Class.forName("dh_sqlite.JDBC");
        jdbcPrefix = (String)driver.getField("PREFIX").get(null);
        check("jdbc:dh_sqlite:".equals(jdbcPrefix), "actual relocated JDBC protocol");
        boolean write = args[0].equals("write");
        database(Paths.get(temp, "amcl-sqlite-qa-1112-r3"), write);
        database(Paths.get(args[1]), write);
        System.out.println("AMCL_SQLITE_PERSISTENCE passed=true mode=" + args[0] + " checks=" + checks);
    }
}
