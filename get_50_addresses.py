import requests
import time
import os
from dotenv import load_dotenv
# --- 配置区 ---

# 加载 .env 文件中的环境变量
load_dotenv()

# 从环境变量中读取 API_KEY
API_KEY = os.getenv('API_KEY')
# 加个检查，防止没读到 Key 报错
if not API_KEY:
    raise ValueError("未找到 API_KEY，请确保 .env 文件存在且配置正确！")
TARGET_COUNT = 400       # 我们的目标是 400 个
ADDRESS_FILE = 'addresses.txt'

def get_bulk_addresses():
    addresses = set()
    # 我们从最新的区块开始往回找
    print(f"📡 正在通过 API 挖掘最新的活跃合约地址...")
    
    # 1. 先获取最新区块号
    block_url = f"https://api.etherscan.io/v2/api?chainid=1&module=proxy&action=eth_blockNumber&apikey={API_KEY}"
    current_block = int(requests.get(block_url).json()['result'], 16)

    while len(addresses) < TARGET_COUNT:
        print(f"🔍 正在扫描区块 {current_block}, 目前已搜集 {len(addresses)}/{TARGET_COUNT}...")
        
        # 2. 获取该区块内的所有交易
        tx_url = f"https://api.etherscan.io/v2/api?chainid=1&module=proxy&action=eth_getBlockByNumber&tag={hex(current_block)}&boolean=true&apikey={API_KEY}"
        response = requests.get(tx_url).json()
        
        if 'result' in response and response['result']:
            transactions = response['result']['transactions']
            for tx in transactions:
                # to 字段通常是合约地址
                if tx.get('to'):
                    addresses.add(tx['to'].lower())
                if len(addresses) >= TARGET_COUNT:
                    break
        
        current_block -= 1 # 往前的区块找
        time.sleep(0.2) # 稍微歇息一下，别被封了

    # 3. 保存到文件
    with open(ADDRESS_FILE, 'w') as f:
        for addr in addresses:
            f.write(addr + '\n')
    
    print(f"✨ 大功告成！400个地址已存入 {ADDRESS_FILE}")

if __name__ == "__main__":
    get_bulk_addresses()