import SwiftUI
import Combine

// 用于跟踪产品列表视图生命周期
final class ProductListViewModel: ObservableObject {
    @Published var currentDisplayId: String = ""
    private var cancellables = Set<AnyCancellable>()
    weak var statusBarViewModel: StatusBarViewModel?
    
    init(statusBarViewModel: StatusBarViewModel) {
        self.statusBarViewModel = statusBarViewModel
        
        // 同步当前显示ID (使用弱引用避免循环)
        self.currentDisplayId = statusBarViewModel.currentDisplayProduct?.instId ?? ""
        
        // 设置订阅
        statusBarViewModel.objectWillChange
            .throttle(for: 0.5, scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                guard let self = self, let viewModel = self.statusBarViewModel else { return }
                self.currentDisplayId = viewModel.currentDisplayProduct?.instId ?? ""
            }
            .store(in: &cancellables)
    }
    
    func setDisplayProduct(_ product: CryptoProduct) {
        // 更新本地状态
        self.currentDisplayId = product.instId
        
        // 异步设置，避免视图更新循环
        DispatchQueue.main.async { [weak self] in
            self?.statusBarViewModel?.selectDisplayProduct(product)
        }
    }
    
    // 清理所有订阅
    func cleanup() {
        statusBarViewModel = nil
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }
    
    // 析构时自动清理
    deinit {
        cleanup()
        print("ProductListViewModel 已释放")
    }
}

struct ProductListView: View {
    @ObservedObject var cryptoService: CryptoService
    // 使用视图模型进行内存管理
    @StateObject private var viewModel: ProductListViewModel
    @EnvironmentObject var appSettings: AppSettings
    
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var selectedTab = 0 // 0:收藏, 1:所有产品
    @State private var isProductsLoaded = false // 添加标志，懒加载产品
    @State private var selectedProductType: ProductType = .SPOT // 默认选择币币
    
    // 初始化时创建视图模型
    init(cryptoService: CryptoService, statusBarViewModel: StatusBarViewModel) {
        self.cryptoService = cryptoService
        self._viewModel = StateObject(wrappedValue: ProductListViewModel(statusBarViewModel: statusBarViewModel))
    }
    
    // 过滤收藏产品列表
    private var filteredFavorites: [CryptoProduct] {
        // 首先按产品类型过滤收藏夹，确保只显示当前选择类型的产品
        let typeFilteredProducts = cryptoService.favoriteProducts.filter { product in
            // 添加额外的健壮性处理，确保产品类型与其ID特征一致
            let instId = product.instId
            let expectedType = instId.contains("-SWAP") ? ProductType.SWAP :
                              instId.contains("-FUTURES") ? ProductType.FUTURES :
                              instId.contains("-OPTION") ? ProductType.OPTION :
                              ProductType.SPOT
            
            // 如果产品类型与预期不一致，打印警告并使用ID特征判断
            if product.productType != expectedType {
                print("警告: 产品 \(instId) 的类型(\(product.productType.displayName))与其ID特征不一致，应为 \(expectedType.displayName)")
                // 根据ID特征判断是否应该显示
                return expectedType == selectedProductType
            }
            
            // 正常判断产品类型是否匹配当前选择的类型
            return product.productType == selectedProductType
        }
        
        // 然后再按搜索词过滤
        if searchText.isEmpty {
            return typeFilteredProducts
        } else {
            return typeFilteredProducts.filter {
                $0.instId.lowercased().contains(searchText.lowercased()) ||
                $0.baseCcy.lowercased().contains(searchText.lowercased())
            }
        }
    }
    
    // 过滤所有产品列表，不限制数量
    private var filteredProducts: [CryptoProduct] {
        // 如果未加载产品或不在"所有产品"标签，返回空
        if !isProductsLoaded || selectedTab != 1 {
            return []
        }
        
        // 先按产品类型过滤
        let typeFilteredProducts = cryptoService.products.filter {
            $0.productType == selectedProductType
        }
        
        if searchText.isEmpty {
            return typeFilteredProducts
        } else {
            // 按搜索词过滤
            return typeFilteredProducts.filter {
                $0.instId.lowercased().contains(searchText.lowercased()) ||
                $0.baseCcy.lowercased().contains(searchText.lowercased())
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 产品类型选择器
            HStack {
                Text("产品类型:")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
                
                Picker("", selection: $selectedProductType) {
                    ForEach(ProductType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .onChange(of: selectedProductType) { newType in
                    // 当产品类型改变时，保存设置并刷新数据
                    appSettings.saveSelectedProductType(newType.rawValue)
                    
                    // 如果在"所有产品"标签，重新加载产品列表
                    if selectedTab == 1 {
                        // 重新加载产品
                        DispatchQueue.global(qos: .userInitiated).async {
                            cryptoService.fetchAllProducts()
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            
            // 搜索栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("搜索...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .onTapGesture {
                        isSearching = true
                    }
                
                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.top, 8) // 减小顶部边距，给产品类型选择器腾出空间
            
            // 分段控制
            Picker("", selection: $selectedTab) {
                Text("收藏").tag(0)
                Text("所有产品").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .onChange(of: selectedTab) { newTab in
                // 当切换到"所有产品"选项卡时，才加载产品
                if newTab == 1 && !isProductsLoaded {
                    isProductsLoaded = true
                    
                    // 确保加载当前选择的产品类型
                    DispatchQueue.global(qos: .userInitiated).async {
                        cryptoService.fetchAllProducts()
                    }
                }
            }
            
            // 内容区 - 使用条件渲染替代TabView
            ZStack {
                if selectedTab == 0 {
                    FavoritesListView(
                        favorites: filteredFavorites, 
                        currentDisplayId: viewModel.currentDisplayId,
                        onSetDisplay: { product in
                            viewModel.setDisplayProduct(product)
                        },
                        onRemoveFavorite: { product in
                            // 安全地处理收藏移除
                            safeRemoveFavorite(product)
                        },
                        selectedTab: $selectedTab
                    )
                } else {
                    AllProductsListView(
                        products: filteredProducts,
                        favorites: cryptoService.favoriteProducts,
                        cryptoService: cryptoService
                    )
                }
            }
            .frame(height: 350) // 减小高度，给产品类型选择器腾出空间
            
            // 底部按钮区域
            HStack {
                Button(action: {
                    if selectedTab == 0 {
                        // 如果在收藏标签页，只刷新收藏产品
                        DispatchQueue.global(qos: .utility).async {
                            cryptoService.refreshFavoriteProducts()
                        }
                    } else {
                        // 否则刷新所有产品
                        DispatchQueue.global(qos: .utility).async {
                            cryptoService.fetchAllProducts()
                        }
                    }
                }) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                
                Spacer()
                
                ConnectionStatusView(status: cryptoService.connectionStatus)
                
                Spacer()
                
                Button(action: {
                    if let url = URL(string: "https://www.okx.com") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Label("访问OKX官网", systemImage: "globe")
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 400, height: 500)
        .onAppear {
            // 初始化时从设置中加载选择的产品类型
            selectedProductType = appSettings.getCurrentProductType()
        }
    }
    
    // 安全地移除收藏
    private func safeRemoveFavorite(_ product: CryptoProduct) {
        // 异步处理，避免视图更新时修改数据
        DispatchQueue.main.async {
            self.cryptoService.removeFavorite(product)
        }
    }
}

// 收藏列表视图
struct FavoritesListView: View {
    let favorites: [CryptoProduct]
    let currentDisplayId: String
    let onSetDisplay: (CryptoProduct) -> Void
    let onRemoveFavorite: (CryptoProduct) -> Void
    
    // 用于管理拖放状态
    @State private var draggedItem: CryptoProduct?
    @ObservedObject private var cryptoService = CryptoService.shared
    // 添加绑定到父视图的selectedTab
    @Binding var selectedTab: Int
    
    var body: some View {
        if favorites.isEmpty {
            VStack {
                Image(systemName: "star.slash")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                    .padding()
                
                Text("收藏列表为空")
                    .font(.headline)
                
                Text("添加收藏以在菜单栏中显示价格")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                
                Button("浏览产品列表") {
                    // 切换到产品列表页面(selectedTab值为1)
                    selectedTab = 1
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(favorites) { product in
                        FavoriteRowView(
                            product: product,
                            isCurrentDisplay: product.instId == currentDisplayId,
                            onSetDisplay: {
                                onSetDisplay(product)
                            },
                            onRemoveFavorite: {
                                onRemoveFavorite(product)
                            }
                        )
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                        .background(
                            draggedItem?.id == product.id ? 
                                Color(NSColor.selectedContentBackgroundColor).opacity(0.5) : 
                                Color.clear
                        )
                        // 启用拖动功能
                        .onDrag {
                            self.draggedItem = product
                            // 返回NSItemProvider，标识正在拖动的项目
                            return NSItemProvider(object: product.id as NSString)
                        }
                        // 启用放置功能
                        .onDrop(of: [.text], delegate: DragReorderDelegate(
                            item: product,
                            draggedItem: $draggedItem,
                            favorites: favorites,
                            cryptoService: cryptoService)
                        )
                        Divider()
                    }
                }
                .padding(.top, 4)
                .animation(.default, value: favorites) // 为拖拽排序添加动画
            }
        }
    }
}

// 拖拽排序的代理实现
struct DragReorderDelegate: DropDelegate {
    let item: CryptoProduct
    @Binding var draggedItem: CryptoProduct?
    let favorites: [CryptoProduct]
    let cryptoService: CryptoService
    
    func validateDrop(info: DropInfo) -> Bool {
        // 只允许同一列表内的拖放
        return draggedItem != nil
    }
    
    func dropEntered(info: DropInfo) {
        // 确保有拖动项
        guard let draggedItem = self.draggedItem, 
              draggedItem.id != item.id,
              let fromIndex = favorites.firstIndex(where: { $0.id == draggedItem.id }),
              let toIndex = favorites.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        
        // 如果拖动中的项进入了一个新的位置，重新排序列表
        withAnimation {
            // 获取可变的收藏夹列表
            var updatedFavorites = cryptoService.favoriteProducts
            
            // 移除拖动项
            let movedItem = updatedFavorites.remove(at: fromIndex)
            
            // 插入到新位置
            updatedFavorites.insert(movedItem, at: toIndex)
            
            // 更新收藏列表
            cryptoService.reorderFavorites(updatedFavorites)
        }
    }
    
    func performDrop(info: DropInfo) -> Bool {
        // 清空拖动状态
        draggedItem = nil
        return true
    }
}

// 收藏行视图 - 简化为纯功能组件
struct FavoriteRowView: View {
    let product: CryptoProduct
    let isCurrentDisplay: Bool
    let onSetDisplay: () -> Void
    let onRemoveFavorite: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack {
                    Text(product.baseCcy)
                        .font(.headline)
                    
                    Text(product.quoteCcy)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    if isCurrentDisplay {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                            .font(.caption)
                    }
                }
                
                Text(product.instId)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            VStack(alignment: .trailing) {
                Text(product.formattedPrice)
                    .font(.headline.monospacedDigit())
                    .foregroundColor(priceColor)
                
                getPriceChangeText()
            }
            
            // 按钮区域
            HStack(spacing: 12) {
                Button(action: onRemoveFavorite) {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                        .imageScale(.large)
                }
                .buttonStyle(PlainButtonStyle())
                
                Button(action: onSetDisplay) {
                    Image(systemName: "display")
                        .foregroundColor(isCurrentDisplay ? .accentColor : .gray)
                        .imageScale(.large)
                }
                .buttonStyle(PlainButtonStyle())
                .opacity(isCurrentDisplay ? 1.0 : 0.7)
                .help(isCurrentDisplay ? "当前显示在菜单栏" : "设置显示在菜单栏")
            }
            .padding(.leading, 8)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(Color(NSColor.controlBackgroundColor).opacity(0.01))
    }
    
    // 价格颜色 - 使用工具类
    private var priceColor: Color {
        PriceColorHelper.priceColor(for: product)
    }

    // 返回涨跌幅文本视图 - 使用可复用组件
    private func getPriceChangeText() -> some View {
        PriceChangeText(product: product)
    }
}

// 所有产品列表视图
struct AllProductsListView: View {
    let products: [CryptoProduct]
    let favorites: [CryptoProduct]
    let cryptoService: CryptoService

    // 判断是否已收藏
    private func isFavorite(_ product: CryptoProduct) -> Bool {
        return favorites.contains { $0.instId == product.instId }
    }

    var body: some View {
        if products.isEmpty {
            // 改进的加载状态视图
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.2)
                    .padding()

                Text("正在加载产品列表...")
                    .font(.headline)

                Text("首次加载可能需要几秒钟")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // 连接状态提示
                if cryptoService.connectionStatus != .connected {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(cryptoService.connectionStatus == .connecting ? Color.yellow : Color.red)
                            .frame(width: 8, height: 8)
                        Text(cryptoService.connectionStatus.rawValue)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(products) { product in
                            CryptoProductRow(
                                product: product,
                                isFavorite: isFavorite(product),
                                isCurrentDisplay: false,
                                onToggleFavorite: {
                                    if isFavorite(product) {
                                        cryptoService.removeFavorite(product)
                                    } else {
                                        cryptoService.addFavorite(product)
                                    }
                                },
                                onSelectDisplay: { }
                            )
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                    .padding(.top, 4)
                }
            
        }
    }
}

// 加密货币行组件
struct CryptoProductRow: View {
    let product: CryptoProduct
    let isFavorite: Bool
    let isCurrentDisplay: Bool
    let onToggleFavorite: () -> Void
    let onSelectDisplay: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack {
                    Text(product.baseCcy)
                        .font(.headline)
                    
                    Text(product.quoteCcy)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    if isCurrentDisplay {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                            .font(.caption)
                    }
                }
                
                Text(product.instId)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            VStack(alignment: .trailing) {
                Text(product.formattedPrice)
                    .font(.headline.monospacedDigit())
                    .foregroundColor(priceColor)
                
                getPriceChangeText()
            }
            
            // 收藏和显示按钮 - 修复高亮逻辑
            HStack(spacing: 12) {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundColor(isFavorite ? .yellow : .gray)
                        .imageScale(.large)
                }
                .buttonStyle(PlainButtonStyle())
                
                if isFavorite {
                    Button(action: onSelectDisplay) {
                        Image(systemName: "display")
                            .foregroundColor(isCurrentDisplay ? .accentColor : .gray)
                            .imageScale(.large)
                    }
                    .buttonStyle(PlainButtonStyle())
                    // 使用isCurrentDisplay来控制按钮是否高亮，但不禁用按钮
                    .opacity(isCurrentDisplay ? 1.0 : 0.7)
                    .help(isCurrentDisplay ? "当前显示在菜单栏" : "设置显示在菜单栏")
                }
            }
            .padding(.leading, 8)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(Color(NSColor.controlBackgroundColor).opacity(0.01)) // 透明背景使整行可点击
    }
    
    // 价格颜色 - 使用工具类
    private var priceColor: Color {
        PriceColorHelper.priceColor(for: product)
    }

    // 返回涨跌幅文本视图 - 使用可复用组件
    private func getPriceChangeText() -> some View {
        PriceChangeText(product: product)
    }
}

// 连接状态视图
struct ConnectionStatusView: View {
    let status: ConnectionStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(status.rawValue)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .disconnected:
            return .gray
        case .failed:
            return .red
        }
    }
} 