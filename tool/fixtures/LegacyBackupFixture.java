import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import javax.crypto.*;
import javax.crypto.spec.*;

class LegacyBackupFixture {
  public static void main(String[] args) throws Exception {
    String payload = """
      {"schema":1,"package":"com.asterlink.app","createdAt":1700000000000,
       "settings":{"theme":"Dark","threads":32,"concurrent":2,"retries":4,"speedLimit":65536,"downloadThreadOverrides":{"uc":128}},
       "credentials":[{"platform":"Quark","credential":{"label":"夸克","updatedAt":42,"fields":{"primary":"__pus=fixture; __puus=test-only"}}},
                      {"platform":"Pan123","credential":{"label":"123","updatedAt":43,"fields":{"primary":"fixture-account","secondary":"fixture-password"}}}],
       "secrets":{"xunlei.device_id":"00000000000000000000000000000000","pan123.login_uuid":"fixture-uuid"}}
      """;
    byte[] salt = new byte[16], iv = new byte[12];
    for(int i=0;i<salt.length;i++) salt[i]=(byte)i;
    for(int i=0;i<iv.length;i++) iv[i]=(byte)(i+16);
    PBEKeySpec spec = new PBEKeySpec("测试密码123".toCharArray(),salt,210000,256);
    byte[] key=SecretKeyFactory.getInstance("PBKDF2WithHmacSHA1").generateSecret(spec).getEncoded();
    Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(Cipher.ENCRYPT_MODE,new SecretKeySpec(key,"AES"),new GCMParameterSpec(128,iv));
    String encoded=Base64.getEncoder().encodeToString(cipher.doFinal(payload.getBytes(StandardCharsets.UTF_8)));
    String envelope="{\"format\":\"asterlink-backup-v1\",\"kdf\":\"PBKDF2WithHmacSHA1\",\"iterations\":210000,\"salt\":\""+
      Base64.getEncoder().encodeToString(salt)+"\",\"iv\":\""+Base64.getEncoder().encodeToString(iv)+"\",\"data\":\""+encoded+"\"}";
    Path output=Path.of(args[0]); Files.createDirectories(output.getParent());
    Files.writeString(output,envelope,StandardCharsets.UTF_8);
    System.out.println("Generated deterministic JVM AES-GCM/PBKDF2 fixture.");
  }
}
