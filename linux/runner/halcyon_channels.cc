#include "halcyon_channels.h"

#include <errno.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <glib-unix.h>
#include <stdio.h>
#include <unistd.h>

struct _HalcyonChannels {
  FlMethodChannel* trash;
  FlMethodChannel* open_with;
  FlMethodChannel* memory_pressure;
  int   psi_fd;                     // -1 when PSI is unavailable
  guint psi_source_id;              // 0 when not armed
  guint psi_decay_timeout_id;       // 0 unless currently in `warning`
  const char* last_pressure_level;  // static string, NULL until the first push
};

// trash_service.dart:7 — channel name.
static constexpr char kTrashChannel[] = "halcyon/trash";
// trash_service.dart:11 — method name and argument-map key.
static constexpr char kTrashMethod[] = "trashFile";
static constexpr char kPathKey[] = "path";
// open_with_channel.dart:30 (channel), :36 (method).
static constexpr char kOpenWithChannel[] = "halcyon/open_with";
static constexpr char kOpenFileMethod[] = "openFile";
// memory_pressure_monitor.dart:73 — channel name. Pushed for real on Linux
// from a PSI trigger (OQ-R5 reversed the earlier register-and-silent plan);
// design and rejected alternatives:
// docs/logs/2026-09-12/detail-linux-psi.md. Chosen interface is the
// system-wide /proc/pressure/memory file, NOT this app's own cgroup: the
// macOS (DispatchSource.makeMemoryPressureSource) and Windows
// (CreateMemoryResourceNotification) producers are both host-wide, and the
// cgroup path adds compile-invisible failure modes (path parse, mount
// layout, controller enablement, delegation) for a signal that, absent a
// memory limit, the system-wide file already reports. If a cgroup-scoped
// signal is ever wanted, ADD a second trigger and take the more severe --
// do not swap this one out, which would change the channel's meaning with
// no visible diff at the Dart boundary.
static constexpr char kMemoryPressureChannel[] = "halcyon/memory_pressure";
// memory_pressure_monitor.dart:78 — method name; argument is a bare String.
static constexpr char kMemoryPressureMethod[] = "memoryPressureLevelChanged";
// Two-state on Linux by lead ruling: the third (most severe) level is a
// macOS platform capability and must NOT be invented here (gated by clause
// S1.11). PSI's
// `full` line would be a defensible third tier (kernel-reported, not
// invented) but ships an unmeasured threshold on a path CI cannot exercise;
// it is parking-lot work, not part of this channel.
static constexpr char kLevelNormal[] = "normal";
static constexpr char kLevelWarning[] = "warning";
// PSI trigger: 200 ms of partial memory stall inside a 2 s window. `some`,
// not `full` -- `full` means every non-idle task is stalled, i.e. the
// machine is already frozen, too late for a decode-budget warning. The
// trailing newline is load-bearing: psi_write() NUL-overwrites the write
// buffer's last byte, so a write without it silently arms a different
// window (and would additionally fail EINVAL, because 200000us is not a 2s
// multiple, the rule the kernel enforces for unprivileged writers). 2s is
// the smallest window an unprivileged process may use, so this needs no
// privilege at all. One trigger per fd: a second write to the same fd fails
// EBUSY (not attempted here -- only one trigger is ever armed).
static constexpr char kPsiPath[] = "/proc/pressure/memory";
static constexpr char kPsiTrigger[] = "some 200000 2000000\n";
// Threshold for leaving `warning`: PSI never delivers a "pressure ended"
// event, so a periodic timeout re-reads `some avg10` after entering warning
// and pushes `normal` once the 10s average decays below this. Hysteresis is
// structural (assert at 10% instantaneous stall, de-assert at 1% of a 10s
// average), so a machine hovering at the threshold cannot flap.
static constexpr double kNormalAvg10Threshold = 1.00;
static constexpr guint kDecayPollSeconds = 2;

static FlMethodResponse* handle_trash_file(FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "INVALID_ARGS", "Missing path", nullptr));
  }
  FlValue* path_value = fl_value_lookup_string(args, kPathKey);
  if (path_value == nullptr ||
      fl_value_get_type(path_value) != FL_VALUE_TYPE_STRING) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "INVALID_ARGS", "Missing path", nullptr));
  }
  const gchar* path = fl_value_get_string(path_value);
  if (path == nullptr || path[0] == '\0') {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "INVALID_ARGS", "Missing path", nullptr));
  }

  g_autoptr(GFile) file = g_file_new_for_path(path);
  g_autoptr(GError) error = nullptr;
  if (!g_file_trash(file, nullptr, &error)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "TRASH_FAILED",
        error != nullptr ? error->message : "Failed to move file to trash",
        nullptr));
  }
  // trash_service.dart:11 awaits invokeMethod<void>: success with a null result.
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static void trash_method_call_cb(FlMethodChannel* channel,
                                 FlMethodCall* method_call,
                                 gpointer user_data) {
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(fl_method_call_get_name(method_call), kTrashMethod) == 0) {
    response = handle_trash_file(fl_method_call_get_args(method_call));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond on %s: %s", kTrashChannel, error->message);
  }
}

// Pushes `level` on halcyon/memory_pressure if it differs from the last
// pushed level. `level` must be a static string literal (kLevelNormal /
// kLevelWarning) -- the pointer, not the contents, is compared, matching the
// last_level de-dup contract Windows' PushMemoryPressureLevel and macOS'
// lastMemoryPressureLevel already enforce (Dart also de-dups independently
// at memory_pressure_monitor.dart:116, so this is a belt-and-braces match,
// not the only line of defence).
static void push_pressure_level(HalcyonChannels* self, const char* level) {
  if (self->last_pressure_level == level) return;
  self->last_pressure_level = level;
  g_autoptr(FlValue) argument = fl_value_new_string(level);
  fl_method_channel_invoke_method(self->memory_pressure,
                                  kMemoryPressureMethod, argument, nullptr,
                                  nullptr, nullptr);
  g_message("memory pressure -> %s", level);
}

// Reads the first line of /proc/pressure/memory and parses `avg10` out of
// the `some ...` line, e.g. "some avg10=12.34 avg60=3.21 avg300=0.10
// total=123456". Returns FALSE (and leaves *avg10 untouched) if the file
// cannot be read or parsed -- the caller treats that the same as "still
// pressured" so a transient read failure cannot prematurely clear a
// warning.
static gboolean read_some_avg10(double* avg10) {
  g_autoptr(GError) error = nullptr;
  g_autofree gchar* contents = nullptr;
  if (!g_file_get_contents(kPsiPath, &contents, nullptr, &error)) {
    return FALSE;
  }
  double parsed = 0.0;
  if (sscanf(contents, "some avg10=%lf", &parsed) != 1) {
    return FALSE;
  }
  *avg10 = parsed;
  return TRUE;
}

static gboolean psi_decay_tick_cb(gpointer user_data) {
  HalcyonChannels* self = static_cast<HalcyonChannels*>(user_data);
  double avg10 = 0.0;
  if (read_some_avg10(&avg10) && avg10 < kNormalAvg10Threshold) {
    push_pressure_level(self, kLevelNormal);
    self->psi_decay_timeout_id = 0;
    return G_SOURCE_REMOVE;
  }
  return G_SOURCE_CONTINUE;
}

// Called on POLLPRI (pressure crossed the armed threshold) or on
// POLLERR/POLLHUP (the kernel says the event source is gone). Runs on the
// default GMainContext, which on a GTK app is the platform thread -- the
// only thread from which fl_method_channel_invoke_method() may be called,
// so no watcher thread or cross-thread hop is needed here (unlike Windows,
// which needs a thread + a message-only window + PostMessage purely to get
// back to the platform thread). Do not "restore parity" by adding one.
static gboolean psi_ready_cb(gint fd, GIOCondition condition,
                             gpointer user_data) {
  HalcyonChannels* self = static_cast<HalcyonChannels*>(user_data);
  if (condition & (G_IO_ERR | G_IO_HUP)) {
    close(self->psi_fd);
    self->psi_fd = -1;
    self->psi_source_id = 0;
    return G_SOURCE_REMOVE;
  }
  push_pressure_level(self, kLevelWarning);
  if (self->psi_decay_timeout_id == 0) {
    self->psi_decay_timeout_id =
        g_timeout_add_seconds(kDecayPollSeconds, psi_decay_tick_cb, self);
  }
  return G_SOURCE_CONTINUE;
}

// Arms the PSI trigger. Degradation on any failure is total, silent, and
// identical to today's behaviour: close the fd, arm nothing, never push --
// the channel stays constructed so Dart's registration still succeeds
// (memory_pressure_monitor.dart:89-92 already declares "calm is the correct
// assumption" safe for a channel that never pushes). No polling fallback
// against a different pseudo-file for PSI-less kernels: a differently-
// calibrated second pressure source is exactly the "invent a threshold the
// OS does not provide" failure the standing ruling forbids.
static void arm_psi_trigger(HalcyonChannels* self) {
  self->psi_fd = open(kPsiPath, O_RDWR | O_CLOEXEC);
  if (self->psi_fd < 0) {
    g_message("PSI unavailable, memory pressure push disabled (open %s: %s)",
              kPsiPath, g_strerror(errno));
    return;
  }
  const ssize_t trigger_len = static_cast<ssize_t>(sizeof(kPsiTrigger) - 1);
  if (write(self->psi_fd, kPsiTrigger, trigger_len) != trigger_len) {
    g_message(
        "PSI trigger write failed, memory pressure push disabled (write %s: "
        "%s)",
        kPsiPath, g_strerror(errno));
    close(self->psi_fd);
    self->psi_fd = -1;
    return;
  }
  self->psi_source_id =
      g_unix_fd_add(self->psi_fd, static_cast<GIOCondition>(G_IO_PRI | G_IO_ERR | G_IO_HUP),
                   psi_ready_cb, self);
  g_message("PSI trigger armed on %s (some 200ms/2s)", kPsiPath);
}

HalcyonChannels* halcyon_channels_new(FlBinaryMessenger* messenger) {
  HalcyonChannels* self = g_new0(HalcyonChannels, 1);
  self->psi_fd = -1;
  self->psi_source_id = 0;
  self->psi_decay_timeout_id = 0;
  self->last_pressure_level = nullptr;

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();

  self->trash = fl_method_channel_new(messenger, kTrashChannel,
                                      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->trash, trash_method_call_cb,
                                            nullptr, nullptr);

  // Push-only, no handler: open_with_channel.dart:5-11 explains why a
  // Dart -> platform call loses the cold-start race.
  self->open_with = fl_method_channel_new(messenger, kOpenWithChannel,
                                          FL_METHOD_CODEC(codec));
  // Push-only, no handler: memory_pressure_monitor.dart never calls into the
  // platform, it only listens.
  self->memory_pressure = fl_method_channel_new(
      messenger, kMemoryPressureChannel, FL_METHOD_CODEC(codec));

  arm_psi_trigger(self);

  return self;
}

void halcyon_channels_push_open_file(HalcyonChannels* self,
                                     const gchar* path) {
  if (self == nullptr || path == nullptr || path[0] == '\0') return;
  g_autoptr(FlValue) argument = fl_value_new_string(path);
  fl_method_channel_invoke_method(self->open_with, kOpenFileMethod, argument,
                                  nullptr, nullptr, nullptr);
}

void halcyon_channels_free(HalcyonChannels* self) {
  if (self == nullptr) return;
  // Ordering is load-bearing: both GSources must be gone BEFORE anything they
  // touch. Every source runs on this same thread, so there is no race -- but
  // an un-removed source holding `self` past g_free is a use-after-free the
  // compiler will not catch. (Windows' destructor documents the same hazard
  // for its watcher thread; here it reduces to two g_clear_handle_id calls.)
  g_clear_handle_id(&self->psi_decay_timeout_id, g_source_remove);
  g_clear_handle_id(&self->psi_source_id, g_source_remove);
  if (self->psi_fd >= 0) close(self->psi_fd);
  g_clear_object(&self->trash);
  g_clear_object(&self->open_with);
  g_clear_object(&self->memory_pressure);
  g_free(self);
}
