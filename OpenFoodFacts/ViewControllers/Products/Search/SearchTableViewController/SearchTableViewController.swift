//
//  SearchTableViewController.swift
//  OpenFoodFacts
//
//  Created by Andrés Pizá Bückmann on 10/04/2017.
//  Copyright © 2017 Andrés Pizá Bückmann. All rights reserved.
//

import UIKit
import CoreGraphics
import Fabric
import Crashlytics

// MARK: - UIViewController

class SearchTableViewController: UIViewController {
    @IBOutlet weak var tableView: UITableView!
    var searchController: UISearchController!
    var productApi: ProductApi!
    var queryRequestWorkItem: DispatchWorkItem?
    var tapGestureRecognizer: UITapGestureRecognizer?
    var state = State.initial {
        didSet {
            switch state {
            case .initial: tableView.backgroundView = initialView
            case .loading: tableView.backgroundView = loadingView
            case .empty: tableView.backgroundView = emptyView
            case .content: tableView.backgroundView = nil
            case .error: tableView.backgroundView = errorView
            }
            self.tableView.reloadData()
        }
    }

    // Background views
    // swiftlint:disable:next force_cast
    lazy var initialView = Bundle.main.loadNibNamed("InitialView", owner: self, options: nil)!.first as! UIView
    lazy var loadingView: UIView = LoadingView(frame: self.view.bounds)
    lazy var emptyView: UIView = EmptyView(frame: self.view.bounds)
    lazy var errorView: UIView = ErrorView(frame: self.view.bounds)

    /* When the user searches a product by barcode and it's found, the product's detail view is loaded.
     If the user loads taps the back button, after presenting the search view the app goes back to the product's detail view again.
     This boolean breaks that loop. */
    fileprivate var wasSearchBarEdited = false

    override func viewDidLoad() {
        super.viewDidLoad()

        configureTableView()
        configureSearchController()
        configureNavigationBar()
        configureGestureRecognizers()
    }

    fileprivate func configureTableView() {
        tableView.backgroundView = initialView // State.initial background view
        tableView.register(UINib(nibName: String(describing: ProductTableViewCell.self), bundle: nil), forCellReuseIdentifier: String(describing: ProductTableViewCell.self))

        tableView.rowHeight = 100
    }

    fileprivate func configureSearchController() {
        searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.dimsBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = NSLocalizedString("product-search.search-placeholder", comment: "Placeholder for the product search bar")
        searchController.searchBar.delegate = self
        searchController.hidesNavigationBarDuringPresentation = false
        definesPresentationContext = true
        tableView.tableHeaderView = searchController.searchBar

        let searchField = searchController.searchBar.value(forKey: "_searchField") as? UITextField
        searchField?.isAccessibilityElement = true
        searchField?.accessibilityIdentifier = AccessibilityIdentifiers.productSearchBar
    }

    fileprivate func configureNavigationBar() {
        let scanButton = UIBarButtonItem(image: UIImage(named: "barcode"), style: .plain, target: self, action: #selector(scanBarcode))
        scanButton.accessibilityIdentifier = AccessibilityIdentifiers.scanButton
        navigationItem.rightBarButtonItem = scanButton
    }

    fileprivate func configureGestureRecognizers() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapTableViewBackground(_:)))
        self.tapGestureRecognizer = tap
    }
}

// MARK: - UITableViewDataSource

extension SearchTableViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        switch state {
        case .content:
            tableView.separatorStyle = .singleLine
            tableView.isScrollEnabled = true

            return 1
        default:
            tableView.separatorStyle = .none
            tableView.isScrollEnabled = false

            if let tap = tapGestureRecognizer {
                tableView.backgroundView?.addGestureRecognizer(tap)
            }

            return 0
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard case let .content(response) = state else { return 0 }
        return response.products.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // swiftlint:disable:next force_cast
        let cell = tableView.dequeueReusableCell(withIdentifier: String(describing: ProductTableViewCell.self), for: indexPath) as! ProductTableViewCell

        guard case let .content(response) = state else { return cell }
        cell.configure(withProduct: response.products[indexPath.row])
        if response.products.count == indexPath.row + 5, let page = Int(response.page), response.products.count < response.totalProducts {
            getProducts(page: page + 1, withQuery: response.query)
        }

        return cell
    }
}

// MARK: - UITableViewDelegate

extension SearchTableViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard case let .content(response) = state else { return }
        showProductDetails(product: response.products[indexPath.row])
    }
}

// MARK: - UISearchResultsUpdating

extension SearchTableViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        queryRequestWorkItem?.cancel()
        if let query = searchController.searchBar.text, !query.isEmpty, wasSearchBarEdited {
            state = .loading
            let request = DispatchWorkItem { [weak self] in
                self?.getProducts(page: 1, withQuery: query)
            }
            queryRequestWorkItem = request
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: request)
            wasSearchBarEdited = false
        }
    }
}

// MARK: - UISearchBarDelegate

extension SearchTableViewController: UISearchBarDelegate {
    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(true, animated: true)
    }

    func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(false, animated: true)
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        wasSearchBarEdited = true
        if searchText.isEmpty { // x button was tapped or text was deleted
            clearResults()
        }
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        clearResults()
    }

    fileprivate func clearResults() {
        state = .initial
    }
}

// MARK: - Data source

extension SearchTableViewController {
    func getProducts(page: Int, withQuery query: String) {
        productApi.getProducts(for: query, page: page, onSuccess: { response in
            switch self.state {
            case .content(let oldResponse): // Append new products to existing response
                oldResponse.products.append(contentsOf: response.products)
                oldResponse.page = response.page
                oldResponse.pageSize = response.pageSize
                self.state = .content(oldResponse)
            default: // Got new response
                if response.totalProducts == 0 {
                    self.state = .empty
                } else {
                    self.state = .content(response)
                }
            }
        }, onError: { error in
            self.state = .error(error)
        })
    }
}

// MARK: - Gesture recognizers

extension SearchTableViewController {
    func didTapTableViewBackground(_ sender: UITapGestureRecognizer) {
        // When the search bar has no text and the user taps the background view of the table view,
        // ask the search bar to resign focus so it goes back to it's begining state and the keyboard gets dismissed
        if searchController.isActive {
            switch state {
            case .content:
                return
            default:
                if let text = searchController.searchBar.text, text.isEmpty {
                    searchController.searchBar.resignFirstResponder()
                }
            }
        }
    }
}

// MARK: - Private functions
private extension SearchTableViewController {
    func showProductDetails(product: Product) {
        navigationController?.pushViewController(productDetails(product: product), animated: true)
    }

    func productDetails(product: Product) -> ProductDetailViewController {
        let storyboard = UIStoryboard(name: String(describing: ProductDetailViewController.self), bundle: nil)
        // swiftlint:disable:next force_cast
        let productDetailVC = storyboard.instantiateInitialViewController() as! ProductDetailViewController
        productDetailVC.product = product
        productDetailVC.productApi = productApi
        return productDetailVC
    }
}

// MARK: - Scanning

extension SearchTableViewController {
    func scanBarcode() {
        let scanVC = ScannerViewController(productApi: productApi)
        navigationController?.pushViewController(scanVC, animated: true)
    }
}
