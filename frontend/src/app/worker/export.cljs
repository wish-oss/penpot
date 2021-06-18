;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at http://mozilla.org/MPL/2.0/.
;;
;; Copyright (c) UXBOX Labs SL

(ns app.worker.export
  (:require
   [app.common.data :as d]
   [app.config :as cfg]
   [app.main.render :as r]
   [app.main.repo :as rp]
   [app.util.dom :as dom]
   [app.util.http :as http]
   [app.util.json :as json]
   [app.util.zip :as uz]
   [app.worker.impl :as impl]
   [beicon.core :as rx]
   [cuerdas.core :as str]))

(defn create-manifest
  "Creates a manifest entry for the given files"
  [team-id file-id files]
  (letfn [(format-page [manifest page]
            (-> manifest
                (assoc (str (:id page))
                       {:name (:name page)})))

          (format-file [manifest file]
            (let [name      (:name file)
                  is-shared (:is-shared file)
                  pages     (->> (get-in file [:data :pages])
                                 (mapv str))
                  index     (->> (get-in file [:data :pages-index])
                                 (vals)
                                 (reduce format-page {}))]
              (-> manifest
                  (assoc (str (:id file))
                         {:name            name
                          :shared          is-shared
                          :pages           pages
                          :pagesIndex      index
                          :hasComponents   (d/not-empty? (get-in file [:data :components]))
                          :hasImages       (d/not-empty? (get-in file [:data :media]))
                          :hasColors       (d/not-empty? (get-in file [:data :colors]))
                          :hasTypographies (d/not-empty? (get-in file [:data :typographies]))}))))]
    (let [manifest {:teamId (str team-id)
                    :fileId (str file-id)
                    :files (->> (vals files) (reduce format-file {}))}]
      (json/encode manifest))))

(defn process-pages [file]
  (let [pages (get-in file [:data :pages])
        pages-index (get-in file [:data :pages-index])]
    (->> pages
         (map #(hash-map
                :file-id (:id file)
                :data (get pages-index %))))))

(defn get-page-data
  [{file-id :file-id {:keys [id name] :as data} :data}]
  (->> (r/render-page data)
       (rx/map (fn [markup]
                 {:id id
                  :name name
                  :file-id file-id
                  :markup markup}))))

(defn collect-page
  [{:keys [id file-id markup] :as page}]
  [(str file-id "/" id ".svg") markup])

(defn collect-color
  [result color]
  (-> result
      (assoc (str (:id color))
             (->> (select-keys color [:name :color :opacity :gradient])
                  (d/deep-mapm
                   (fn [[k v]]
                     [(-> k str/camel) v]))))))

(def ^:const typography-keys [:name :font-family :font-id :font-size
                              :font-style :font-variant-id :font-weight
                              :letter-spacing :line-height :text-transform])
(defn collect-typography
  [result typography]
  (-> result
      (assoc (str (:id typography))
             (->> (select-keys typography typography-keys)
                  (d/deep-mapm
                   (fn [[k v]]
                     [(-> k str/camel) v]))))))

(defn export-file
  [team-id file-id]

  (let [files-stream
        (->> (rx/merge (rp/query :file {:id file-id})
                       (->> (rp/query :file-libraries {:file-id file-id})
                            (rx/flat-map identity)
                            (rx/map #(assoc % :is-shared true))))
             (rx/reduce #(assoc %1 (:id %2) %2) {})
             (rx/share))

        manifest-stream
        (->> files-stream
             (rx/map #(create-manifest team-id file-id %))
             (rx/map #(vector "manifest.json" %)))

        render-stream
        (->> files-stream
             (rx/flat-map vals)
             (rx/flat-map process-pages)
             (rx/observe-on :async)
             (rx/flat-map get-page-data)
             (rx/share))

        colors-stream
        (->> files-stream
             (rx/flat-map vals)
             (rx/map #(vector (:id %) (get-in % [:data :colors])))
             (rx/filter #(d/not-empty? (second %)))
             (rx/map (fn [[file-id colors]]
                       (let [markup
                             (->> (vals colors)
                                  (reduce collect-color {})
                                  (json/encode))]
                         [(str file-id "/colors.json") markup]))))

        typographies-stream
        (->> files-stream
             (rx/flat-map vals)
             (rx/map #(vector (:id %) (get-in % [:data :typographies])))
             (rx/filter #(d/not-empty? (second %)))
             (rx/map (fn [[file-id typographies]]
                       (let [markup
                             (->> (vals typographies)
                                  (reduce collect-typography {})
                                  (json/encode))]
                         [(str file-id "/typographies.json") markup]))))

        media-stream
        (->> files-stream
             (rx/flat-map vals)
             (rx/map #(vector (:id %) (get-in % [:data :media])))
             (rx/filter #(d/not-empty? (second %)))
             (rx/flat-map
              (fn [[file-id media]]
                (->> media vals (mapv #(assoc % :file-id file-id)))))

             (rx/flat-map
              (fn [media]
                (->> (http/send!
                      {:uri (cfg/resolve-file-media media)
                       :response-type :blob
                       :method :get})
                     (rx/map :body)
                     (rx/map #(vector (str file-id "/images/" (:id media)) %))))))

        pages-stream
        (->> render-stream
             (rx/map collect-page))]

    (rx/merge
     (->> render-stream
          (rx/map #(hash-map
                    :type :progress
                    :file file-id
                    :data (str "Render " (:file-name %) " - " (:name %)))))

     (->> (rx/merge
           manifest-stream
           pages-stream
           #_components-stream
           media-stream
           colors-stream
           typographies-stream)
          (rx/reduce conj [])
          (rx/with-latest-from files-stream)
          (rx/flat-map (fn [[data files]]
                         (->> (uz/compress-files data)
                              (rx/map #(vector (get files file-id) %)))))))))

(defmethod impl/handler :export-file
  [{:keys [team-id project-id files] :as message}]

  (->> (rx/from files)
       (rx/mapcat #(export-file team-id %))
       (rx/map
        (fn [value]
          (if (contains? value :type)
            value
            (let [[file export-blob] value]
              {:type :finish
               :filename (:name file)
               :mtype "application/penpot"
               :description "Penpot export (*.penpot)"
               :uri (dom/create-uri export-blob)}))))))
