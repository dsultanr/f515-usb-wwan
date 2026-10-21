/* Bounded Android 11/arm64 experiment. Loads a Java Binder wrapper, no ART patches.
 * Entry points return quickly; JNI work runs on a separate attached thread. */
#define _GNU_SOURCE
#include <jni.h>
#include <android/log.h>
#include <dlfcn.h>
#include <elf.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "art-symbol.h"
#include "build/cells-dex.h"

#define LOG(...) __android_log_print(ANDROID_LOG_WARN, "WwanCells", __VA_ARGS__)
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static jclass bridge;

static int exception(JNIEnv *env, const char *phase) {
    if (!(*env)->ExceptionCheck(env)) return 0;
    LOG("JNI failed: %s", phase);
    (*env)->ExceptionDescribe(env);
    (*env)->ExceptionClear(env);
    return -1;
}

static int exemptions(JNIEnv *env) {
    jclass cls = (*env)->FindClass(env, "dalvik/system/VMRuntime");
    if (!cls) return -1;
    jmethodID get = (*env)->GetStaticMethodID(env, cls, "getRuntime", "()Ldalvik/system/VMRuntime;");
    if (!get) return -1;
    jobject runtime = (*env)->CallStaticObjectMethod(env, cls, get);
    if (!runtime || exception(env, "VMRuntime")) return -1;
    jmethodID set = (*env)->GetMethodID(env, cls, "setHiddenApiExemptions", "([Ljava/lang/String;)V");
    if (!set) return -1;
    jclass string = (*env)->FindClass(env, "java/lang/String");
    jstring prefix = (*env)->NewStringUTF(env, "L");
    if (!string || !prefix) return -1;
    jobjectArray list = (*env)->NewObjectArray(env, 1, string, prefix);
    if (!list) return -1;
    (*env)->CallVoidMethod(env, runtime, set, list);
    return exception(env, "hidden API access");
}

static int load(JNIEnv *env, jobject app) {
    if (bridge) return 0;
    jobject parent;
    if (app) {
        jclass appcls = (*env)->GetObjectClass(env, app);
        jmethodID loader = (*env)->GetMethodID(env, appcls, "getClassLoader", "()Ljava/lang/ClassLoader;");
        if (!loader) return -1;
        parent = (*env)->CallObjectMethod(env, app, loader);
    } else {
        jclass loadercls = (*env)->FindClass(env, "java/lang/ClassLoader");
        if (!loadercls) return -1;
        jmethodID loader = (*env)->GetStaticMethodID(env, loadercls, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
        if (!loader) return -1;
        parent = (*env)->CallStaticObjectMethod(env, loadercls, loader);
    }
    if (!parent || exception(env, "app loader")) return -1;
    jclass buffercls = (*env)->FindClass(env, "java/nio/ByteBuffer");
    if (!buffercls) return -1;
    jmethodID wrap = (*env)->GetStaticMethodID(env, buffercls, "wrap", "([B)Ljava/nio/ByteBuffer;");
    if (!wrap) return -1;
    jbyteArray bytes = (*env)->NewByteArray(env, sizeof(cells_dex));
    if (!bytes) return -1;
    (*env)->SetByteArrayRegion(env, bytes, 0, sizeof(cells_dex), (const jbyte *)cells_dex);
    if (exception(env, "dex bytes")) return -1;
    jobject buffer = (*env)->CallStaticObjectMethod(env, buffercls, wrap, bytes);
    if (!buffer || exception(env, "dex buffer")) return -1;
    jclass dexcls = (*env)->FindClass(env, "dalvik/system/InMemoryDexClassLoader");
    if (!dexcls) return -1;
    jmethodID ctor = (*env)->GetMethodID(env, dexcls, "<init>", "(Ljava/nio/ByteBuffer;Ljava/lang/ClassLoader;)V");
    if (!ctor) return -1;
    jobject dex = (*env)->NewObject(env, dexcls, ctor, buffer, parent);
    if (!dex || exception(env, "dex loader")) return -1;
    jmethodID find = (*env)->GetMethodID(env, dexcls, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
    jstring name = (*env)->NewStringUTF(env, "CellRuntimeBridge");
    if (!find || !name) return -1;
    jobject cls = (*env)->CallObjectMethod(env, dex, find, name);
    if (!cls || exception(env, "bridge class")) return -1;
    bridge = (*env)->NewGlobalRef(env, cls);
    return bridge ? 0 : -1;
}

static void *worker(void *arg) {
    pthread_mutex_lock(&mutex);
    JNIEnv *env = NULL;
    JavaVM *vm = NULL;
    jsize count = 0;
    typedef jint (*get_vms_t)(JavaVM **, jsize, jsize *);
    get_vms_t get = (get_vms_t)dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs");
    if (!get) get = (get_vms_t)find_art_symbol("JNI_GetCreatedJavaVMs");
    if (!get || get(&vm, 1, &count) != JNI_OK || count != 1 || !vm) {
        LOG("cannot resolve Java VM"); goto done;
    }
    if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) {
        LOG("cannot attach JNI worker"); goto done;
    }
    if ((*env)->PushLocalFrame(env, 64) != JNI_OK) goto detach;
    int rc = -1;
    if (arg) {
        if (!bridge) { rc = 0; goto finish; }
        jmethodID stop = (*env)->GetStaticMethodID(env, bridge, "stop", "()V");
        if (!stop) goto finish;
        (*env)->CallStaticVoidMethod(env, bridge, stop);
        rc = exception(env, "stop");
    } else {
        if (exemptions(env)) goto finish;
        jclass activity = (*env)->FindClass(env, "android/app/ActivityThread");
        if (!activity) goto finish;
        jmethodID current = (*env)->GetStaticMethodID(env, activity, "currentApplication", "()Landroid/app/Application;");
        if (!current) goto finish;
        jobject app = (*env)->CallStaticObjectMethod(env, activity, current);
        if (exception(env, "application") || load(env, app)) goto finish;
        jmethodID start = (*env)->GetStaticMethodID(env, bridge, "start", "(Landroid/app/Application;)V");
        if (!start) goto finish;
        (*env)->CallStaticVoidMethod(env, bridge, start, app);
        rc = exception(env, "start");
    }
finish:
    exception(env, "worker");
    LOG("native %s pid=%d rc=%d", arg ? "stop" : "start", getpid(), rc);
    (*env)->PopLocalFrame(env, NULL);
detach:
    (*vm)->DetachCurrentThread(vm);
done:
    pthread_mutex_unlock(&mutex);
    return NULL;
}

static int spawn(void *arg) {
    pthread_t thread;
    int rc = pthread_create(&thread, NULL, worker, arg);
    if (rc) return rc;
    pthread_detach(thread);
    return 0;
}
__attribute__((visibility("default"))) int wwan_cells_start(void) { return spawn(NULL); }
__attribute__((visibility("default"))) int wwan_cells_stop(void) { return spawn((void *)1); }
