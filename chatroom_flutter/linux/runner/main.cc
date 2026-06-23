#include "my_application.h"

#include <stdlib.h>

int main(int argc, char** argv) {
  // 设置 GTK IM 模块为 fcitx，使 Flutter TextField 支持中文输入法
  if (getenv("GTK_IM_MODULE") == NULL) {
    setenv("GTK_IM_MODULE", "fcitx", 0);
  }
  if (getenv("XMODIFIERS") == NULL) {
    setenv("XMODIFIERS", "@im=fcitx", 0);
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
