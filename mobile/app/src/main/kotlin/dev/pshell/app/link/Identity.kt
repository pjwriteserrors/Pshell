package dev.pshell.app.link

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.math.BigInteger
import java.net.Socket
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Principal
import java.security.PrivateKey
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509TrustManager
import javax.security.auth.x500.X500Principal

/**
 * The phone's certificate. Its private key is made inside the Android
 * Keystore and never leaves it; the PC knows the certificate's fingerprint
 * from pairing and lets nobody else in.
 */
object Identity {
	private const val ALIAS = "pshell-identity"
	private val store: KeyStore by lazy { KeyStore.getInstance("AndroidKeyStore").apply { load(null) } }

	val certificate: X509Certificate
		@Synchronized get() {
			if (!store.containsAlias(ALIAS)) generate()
			return store.getCertificate(ALIAS) as X509Certificate
		}

	val pem: String
		get() = "-----BEGIN CERTIFICATE-----\n" +
			Base64.encodeToString(certificate.encoded, Base64.NO_WRAP).chunked(64).joinToString("\n") +
			"\n-----END CERTIFICATE-----\n"

	private fun generate() {
		val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
			.setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
			.setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
			// a name of its own: certificates that share one are easy to mix up on the other end
			.setCertificateSubject(X500Principal("CN=pshell phone ${BigInteger(48, java.security.SecureRandom()).toString(16)}"))
			.setCertificateSerialNumber(BigInteger(64, java.security.SecureRandom()))
			.setCertificateNotBefore(Date(System.currentTimeMillis() - 86_400_000L))
			.setCertificateNotAfter(Date(System.currentTimeMillis() + 30L * 365 * 86_400_000L))
			.build()
		KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply { initialize(spec) }.generateKeyPair()
	}

	fun fingerprint(certificate: X509Certificate): String =
		MessageDigest.getInstance("SHA-256").digest(certificate.encoded).joinToString("") { "%02x".format(it) }

	/** Presents the phone's certificate to the PC. */
	private val keyManager = object : X509ExtendedKeyManager() {
		override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = ALIAS
		override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?) = ALIAS
		override fun getCertificateChain(alias: String?) = arrayOf(certificate)
		override fun getPrivateKey(alias: String?) = store.getKey(ALIAS, null) as PrivateKey
		override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf(ALIAS)
		override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = null
		override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?): String? = null
	}

	/** Trusts one certificate: the one whose fingerprint was in the pairing code. */
	class Pin(private val fingerprint: String) : X509TrustManager {
		override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
			val leaf = chain?.firstOrNull() ?: throw CertificateException("No certificate")
			if (!MessageDigest.isEqual(fingerprint(leaf).toByteArray(), fingerprint.lowercase().toByteArray()))
				throw CertificateException("This is not the paired PC")
		}

		override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = throw CertificateException()
		override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
	}

	/** TLS towards one PC; [authenticated] presents the phone's certificate. */
	fun context(pin: Pin, authenticated: Boolean): SSLContext =
		SSLContext.getInstance("TLS").apply { init(if (authenticated) arrayOf(keyManager) else null, arrayOf(pin), null) }
}
