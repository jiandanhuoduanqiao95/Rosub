from pathlib import Path

def combine_files(file_list, output_txt):
    with open(output_txt, 'w', encoding='utf-8') as outfile:
        for file_path in file_list:
            file_path = Path(file_path)
            if not file_path.is_file():
                print(f"警告: 文件 {file_path} 不存在，跳过")
                continue
            outfile.write(f"\n===== 文件: {file_path} =====\n\n")
            with open(file_path, 'r', encoding='utf-8') as infile:
                outfile.write(infile.read())
            outfile.write("\n\n")
            print(f"已添加: {file_path}")

def main():
    files_to_combine = [
        "client/gui/gui_admin_ui.py",
        "client/gui/gui_chat_ui.py",
        "client/gui/gui_group_ui.py",
        "client/gui/gui_login_ui.py",
        "client/gui/gui_main.py",
        "client/gui/gui_message_handler.py",
        "server/server_admin_handler.py",
        "server/server_client_handler.py",
        "server/server_group_handler.py",
        "server/server_main.py",
        "server/server_message_handler.py",
        "database.py",
        "protocol.py"
    ]
    default_txt = "project_files.txt"
    output_txt = input(f"请输入输出的 TXT 文件名（默认: {default_txt}）: ") or default_txt
    try:
        combine_files(files_to_combine, output_txt)
        print(f"\n成功创建 TXT 文件: {output_txt}")
    except Exception as e:
        print(f"错误: {str(e)}")

if __name__ == "__main__":
    main()